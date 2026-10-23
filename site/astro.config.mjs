// @ts-check
import starlight from '@astrojs/starlight';
import { defineConfig } from 'astro/config';
import starlightLinksValidator from 'starlight-links-validator';

const github = 'https://github.com/xuckless/anole';

// The guides come from ../docs (scripts/sync-docs.mjs copies them in before
// every dev and build run); the API reference is Zig's autodoc, copied into
// public/api by the Pages workflow (`zig build docs`).
export default defineConfig({
	site: 'https://xuckless.github.io',
	base: '/anole/',
	trailingSlash: 'always',
	integrations: [
		starlight({
			title: 'Anole',
			description: 'One Zig server for your whole backend: REST, WebSockets, gRPC and WebTransport over HTTP/1.1, HTTP/2 and HTTP/3.',
			logo: { src: './src/assets/icon.svg', alt: 'Anole' },
			favicon: '/favicon.svg',
			social: [{ icon: 'github', label: 'GitHub', href: github }],
			// Pages override this with `editUrl` (their file in docs/).
			editLink: { baseUrl: `${github}/edit/main/` },
			customCss: ['./src/styles/custom.css'],
			head: [
				{ tag: 'meta', attrs: { property: 'og:image', content: 'https://xuckless.github.io/anole/banner.png' } },
				{ tag: 'meta', attrs: { name: 'twitter:image', content: 'https://xuckless.github.io/anole/banner.png' } },
			],
			sidebar: [
				{
					label: 'Guides',
					items: [
						'getting-started',
						'routing',
						'validation',
						'server',
						'config',
						'websocket',
						'webtransport',
						'grpc',
						'clients',
						'database',
						'messaging',
						'resilience',
						'auth',
						'observability',
						'logging',
						'testing',
						'from-fiber',
						'migrating',
						'c-abi',
					],
				},
				{ label: 'API reference', link: '/api/' },
				{
					label: 'Links',
					items: [
						{ label: 'GitHub', link: github },
						{ label: 'Wiki', link: `${github}/wiki` },
						{ label: 'Zigistry', link: 'https://zigistry.dev/packages/github/xuckless/anole' },
						{ label: 'Changelog', link: `${github}/blob/main/CHANGELOG.md` },
					],
				},
			],
			plugins: [
				starlightLinksValidator({
					// The autodoc is not a Starlight page; the workflow checks it exists.
					exclude: ['/anole/api/', '/anole/api/**'],
				}),
			],
		}),
	],
});
