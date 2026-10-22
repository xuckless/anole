import json,os,sys
old_dir,new_dir=sys.argv[1],sys.argv[2]  # new_dir: <client>/result.json per client
clients="quic-go ngtcp2 mvfst quiche kwik picoquic aioquic neqo msquic chrome xquic lsquic quinn s2n-quic go-x-net".split()
sym={'succeeded':'✓','failed':'✕','unsupported':'?'}
def load(p):
    d=json.load(open(p)); return {r['abbr']:r['result'] for r in d['results'][0]}, list(d['tests'])
old={c:load(f"{old_dir}/{c}.result.json")[0] for c in clients}
new={}; tests=None
for c in clients:
    new[c],tests=load(f"{new_dir}/{c}/result.json")
tot={k:0 for k in sym}
rows=["| client | "+" | ".join(tests)+" |","|---|"+"---|"*len(tests)]
for c in clients:
    rows.append(f"| {c} | "+" | ".join(sym[new[c][t]] for t in tests)+" |")
    for t in tests: tot[new[c][t]]+=1
print("\n".join(rows)); print(); print("TOTAL",tot)
ot={k:sum(1 for c in clients for t in tests if old[c][t]==k) for k in sym}; print("OLD",ot)
print("\nDELTA")
for c in clients:
    for t in tests:
        if old[c][t]!=new[c][t]: print(c,t,old[c][t],'->',new[c][t])
