// Copies the guides in ../docs into the Starlight content collection, so the
// site is built from the same Markdown files GitHub shows (nothing is
// committed twice). Run by `npm run dev` and `npm run build` before Astro.
//
// For each docs/<name>.md it writes src/content/docs/<name>.md (gitignored)
// with:
//   - frontmatter: `title` from the H1 (which is removed from the body), a
//     short `description` from the first paragraph, and `editUrl` pointing at
//     docs/<name>.md on GitHub;
//   - guide links (`server.md#limits`) turned into site routes
//     (`/anole/server/#limits`);
//   - other relative repository links (`../README.md#build-flags`,
//     `../examples/io/main.zig`) turned into github.com blob/tree links. A
//     relative link to a file that does not exist fails the sync.
// Code blocks and inline code are left alone.
//
// It also copies the brand assets (assets/icon.svg, assets/banner.png) to
// where Starlight expects them, and the API reference from `zig build docs`
// (zig-out/docs) to public/api when it has been built; all gitignored.

import { copyFileSync, cpSync, existsSync, mkdirSync, readdirSync, readFileSync, rmSync, statSync, writeFileSync } from 'node:fs';
import { dirname, join, posix, relative, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const site = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const repo = resolve(site, '..');
const docsDir = join(repo, 'docs');
const outDir = join(site, 'src', 'content', 'docs');
const base = '/anole/';
const github = 'https://github.com/xuckless/anole';
const branch = 'main';

const problems = [];

// Splits Markdown into code (fenced blocks, inline code spans) and prose, so
// link rewriting touches prose only.
function mapProse(md, fn) {
	const lines = md.split('\n');
	const out = [];
	let fence = null; // the opening fence while inside a fenced block
	let prose = [];
	const flush = () => {
		if (prose.length) out.push(mapInline(prose.join('\n'), fn));
		prose = [];
	};
	for (const line of lines) {
		const m = line.match(/^ {0,3}(`{3,}|~{3,})/);
		if (fence) {
			out.push(line);
			if (m && m[1][0] === fence[0] && m[1].length >= fence.length && line.trim() === m[1]) fence = null;
		} else if (m) {
			flush();
			fence = m[1];
			out.push(line);
		} else {
			prose.push(line);
		}
	}
	flush();
	return out.join('\n');
}

// Applies fn to the text between inline code spans.
function mapInline(text, fn) {
	let result = '';
	let i = 0;
	while (i < text.length) {
		const start = text.indexOf('`', i);
		if (start < 0) {
			result += fn(text.slice(i));
			break;
		}
		result += fn(text.slice(i, start));
		let ticks = 1;
		while (text[start + ticks] === '`') ticks++;
		const delim = '`'.repeat(ticks);
		const end = text.indexOf(delim, start + ticks);
		if (end < 0) {
			result += text.slice(start);
			break;
		}
		result += text.slice(start, end + ticks);
		i = end + ticks;
	}
	return result;
}

function rewriteLink(target, from) {
	if (/^[a-z][a-z0-9+.-]*:/i.test(target) || target.startsWith('#') || target.startsWith('/')) return target;
	const hashAt = target.indexOf('#');
	const path = hashAt < 0 ? target : target.slice(0, hashAt);
	const hash = hashAt < 0 ? '' : target.slice(hashAt);
	const abs = resolve(docsDir, path);
	const rel = relative(repo, abs).split('\\').join('/');
	if (rel.startsWith('..')) {
		problems.push(`${from}: link leaves the repository: ${target}`);
		return target;
	}
	if (!existsSync(abs)) {
		problems.push(`${from}: link to a missing file: ${target}`);
		return target;
	}
	// A guide: its route on this site.
	if (posix.dirname(rel) === 'docs' && rel.endsWith('.md')) {
		return `${base}${posix.basename(rel, '.md')}/${hash}`;
	}
	const kind = statSync(abs).isDirectory() ? 'tree' : 'blob';
	return `${github}/${kind}/${branch}/${rel}${hash}`;
}

// Each guide's H1, so link text that names a guide's file (`[routing.md](...)`)
// reads as its title on the site.
const titles = new Map(
	readdirSync(docsDir)
		.filter((f) => f.endsWith('.md'))
		.map((f) => [f, readFileSync(join(docsDir, f), 'utf8').match(/^# +(.+?)\s*$/m)?.[1]])
		.filter(([, t]) => t),
);

function rewriteLinks(md, from) {
	return mapProse(md, (text) =>
		text
			.replace(/(\]\()([^)\s]+)((?:\s+"[^"]*")?\))/g, (_, open, target, close) => open + rewriteLink(target, from) + close)
			.replace(/\[([a-z0-9-]+\.md)\]\(/g, (m, name) => (titles.has(name) ? `[${titles.get(name)}](` : m)),
	);
}

// The first paragraph as plain text, cut at a sentence end near 160 chars.
function describe(body) {
	const para = body
		.split(/\n\s*\n/)
		.map((p) => p.trim())
		.find((p) => p && !p.startsWith('#') && !p.startsWith('```') && !p.startsWith('|') && !p.startsWith('-'));
	if (!para) return '';
	let text = para
		.replace(/\[([^\]]*)\]\([^)]*\)/g, '$1')
		.replace(/[`*_]/g, '')
		.replace(/\s+/g, ' ')
		.trim();
	// The shortest prefix of 40+ characters that ends a sentence (or a clause
	// before a colon).
	for (const m of text.matchAll(/[.:](?=\s|$)/g)) {
		if (m.index + 1 >= 40) {
			text = text.slice(0, m.index) + '.';
			break;
		}
	}
	if (text.length > 200) text = text.slice(0, 197).replace(/\s+\S*$/, '') + '...';
	return text;
}

const yaml = (s) => JSON.stringify(s); // a JSON string is a valid YAML scalar

mkdirSync(outDir, { recursive: true });
// Remove guides synced earlier (a deleted docs/ file must not linger); the
// committed pages (index.mdx) are kept.
for (const f of readdirSync(outDir)) if (f.endsWith('.md')) rmSync(join(outDir, f));

const guides = readdirSync(docsDir).filter((f) => f.endsWith('.md')).sort();
for (const file of guides) {
	const from = `docs/${file}`;
	const src = readFileSync(join(docsDir, file), 'utf8').replace(/\r\n/g, '\n');
	const h1 = src.match(/^# +(.+?)\s*$/m);
	if (!h1) {
		problems.push(`${from}: no H1 title`);
		continue;
	}
	const body = src.slice(h1.index + h1[0].length).replace(/^\n+/, '');
	const front = [
		'---',
		`title: ${yaml(h1[1])}`,
		`description: ${yaml(describe(body))}`,
		`editUrl: ${yaml(`${github}/edit/${branch}/${from}`)}`,
		'---',
		'',
		'',
	].join('\n');
	writeFileSync(join(outDir, file), front + rewriteLinks(body, from));
}

// Brand assets: the header logo and hero image (src/assets, processed by
// Astro), the favicon and the social card (public, served as they are).
mkdirSync(join(site, 'src', 'assets'), { recursive: true });
mkdirSync(join(site, 'public'), { recursive: true });
copyFileSync(join(repo, 'assets', 'icon.svg'), join(site, 'src', 'assets', 'icon.svg'));
copyFileSync(join(repo, 'assets', 'icon.svg'), join(site, 'public', 'favicon.svg'));
copyFileSync(join(repo, 'assets', 'banner.png'), join(site, 'public', 'banner.png'));

// The API reference: Zig's autodoc from `zig build docs` (../zig-out/docs),
// served at /anole/api/. Without it the site builds, and its API reference
// link points at nothing (the Pages workflow always builds it first).
const apiSrc = join(repo, 'zig-out', 'docs');
const apiDst = join(site, 'public', 'api');
rmSync(apiDst, { recursive: true, force: true });
const haveApi = existsSync(join(apiSrc, 'index.html'));
if (haveApi) cpSync(apiSrc, apiDst, { recursive: true });

if (problems.length) {
	console.error(`sync-docs: ${problems.length} problem(s):\n  ${problems.join('\n  ')}`);
	process.exit(1);
}
console.log(`sync-docs: ${guides.length} guides from docs/ into src/content/docs/; API reference: ${haveApi ? 'zig-out/docs' : 'missing (run `zig build docs` first)'}`);
