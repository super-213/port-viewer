import subprocess, time, resource, statistics, json, socket, os, ipaddress
from pathlib import Path

ROOT=Path(__file__).parent
LSOF=['/usr/sbin/lsof','-nP','-iTCP','-iUDP','-F0pcuLRftnPT']
def endpoint(value):
    if not value: return ('-',0)
    address, _, port=value.rpartition(':')
    if address.startswith('['): address=address[1:-1]
    try: port=int(port)
    except ValueError: port=0
    return address or '*',port
def address(value):
    if value in ('*','0.0.0.0','::',''): return '*'
    try: return str(ipaddress.ip_address(value))
    except ValueError: return value
def normalized(pid,fd,proto,ip,local,lp,remote,rp,state):
    return (int(pid),str(fd),proto,int(ip),address(local),int(lp),address(remote) if int(rp) else '-',int(rp),state)
def parse_lsof(data):
    rows=set(); pid=None; fields={}
    def flush():
        if pid is None or not all(k in fields for k in ('f','P','t','n')): return
        if fields['P'] not in ('TCP','UDP'): return
        pair=fields['n'].split('->',1); local,lp=endpoint(pair[0]); remote,rp=endpoint(pair[1] if len(pair)>1 else '')
        rows.add(normalized(pid,fields['f'],fields['P'],6 if fields['t']=='IPv6' else 4,local,lp,remote,rp,fields.get('state','-')))
    for raw in data.split(b'\0'):
        field=raw.decode('utf-8',errors='replace').strip('\n')
        if not field: continue
        tag,value=field[0],field[1:]
        if tag=='p': flush();fields={};pid=value
        elif tag=='f': flush();fields={'f':value}
        elif tag=='T' and value.startswith('ST='): fields['state']=value[3:]
        else: fields[tag]=value
    flush(); return rows
def lsof():
    before=resource.getrusage(resource.RUSAGE_CHILDREN);start=time.perf_counter()
    result=subprocess.run(LSOF,stdout=subprocess.PIPE,stderr=subprocess.DEVNULL,timeout=10)
    elapsed=(time.perf_counter()-start)*1000;after=resource.getrusage(resource.RUSAGE_CHILDREN)
    cpu=((after.ru_utime+after.ru_stime)-(before.ru_utime+before.ru_stime))*1000
    parsed=parse_lsof(result.stdout)
    return parsed,dict(wall_ms=elapsed,child_cpu_ms=cpu,records=len(parsed),exit=result.returncode)
def native():
    start=time.perf_counter();result=subprocess.run([str(ROOT/'native')],stdout=subprocess.PIPE,check=True,timeout=10)
    elapsed=(time.perf_counter()-start)*1000
    lines=result.stdout.decode().splitlines();m=lines[0].split('\t')[1:]
    keys=['scan_ms','scan_cpu_ms','pids','accessible_pids','fds','socket_fds','records','denied','vanished','other']
    metrics=dict(zip(keys,map(float,m))); metrics['subprocess_wall_ms']=elapsed
    rows={normalized(*line.split('\t')[1:]) for line in lines[1:]}
    return rows,metrics
def summary(values):
    values=sorted(values);return dict(p50=round(statistics.median(values),3),p95=round(values[max(0,int(.95*len(values)+.999)-1)],3),min=round(values[0],3),max=round(values[-1],3))
def benchmark(rounds):
    lsof();native();ls=[];ns=[]
    for i in range(rounds):
        if i%2: _,n=native();_,l=lsof()
        else: _,l=lsof();_,n=native()
        ls.append(l);ns.append(n)
    return dict(rounds=rounds,lsof={k:summary([x[k] for x in ls]) for k in ['wall_ms','child_cpu_ms','records']},native={k:summary([x[k] for x in ns]) for k in ['scan_ms','scan_cpu_ms','subprocess_wall_ms','records','pids','denied','vanished','other']})
fixtures=[]
def make(family,kind):
    s=socket.socket(family,kind); fixtures.append(s)
    if family==socket.AF_INET6: s.setsockopt(socket.IPPROTO_IPV6,socket.IPV6_V6ONLY,1)
    s.bind(('::1' if family==socket.AF_INET6 else '127.0.0.1',0))
    return s
def coverage_fixture():
    for family in [socket.AF_INET,socket.AF_INET6]:
        listener=make(family,socket.SOCK_STREAM);listener.listen()
        client=make(family,socket.SOCK_STREAM);client.connect(listener.getsockname())
        accepted,_=listener.accept();fixtures.append(accepted)
        receiver=make(family,socket.SOCK_DGRAM);sender=make(family,socket.SOCK_DGRAM);sender.connect(receiver.getsockname())
    before,_=lsof();n,nmetrics=native();after,_=lsof()
    stable=before&after; common=stable&n
    owned={r for r in stable if r[0]==os.getpid()}
    return dict(fixture_fds=len(fixtures),fixture_lsof_records=len(owned),fixture_native_matches=len(owned&n),
                stable_lsof_records=len(stable),stable_native_matches=len(common),
                missing_stable_count=len(stable-n),extra_native_count=len(n-(before|after)),
                missing_categories=[dict(protocol=r[2],ip=r[3],state=r[-1],fd_is_numeric=r[1].isdigit()) for r in sorted(stable-n)],
                native_diagnostics=nmetrics)
def main():
    soft,hard=resource.getrlimit(resource.RLIMIT_NOFILE)
    resource.setrlimit(resource.RLIMIT_NOFILE,(min(max(soft,4096),hard),hard))
    results=dict(uid=os.getuid(),machine=subprocess.check_output(['/usr/bin/uname','-m'],text=True).strip(),
                 os=subprocess.check_output(['/usr/bin/sw_vers','-productVersion'],text=True).strip())
    try:
        results['coverage']=coverage_fixture()
        results['baseline']=benchmark(30)
        for _ in range(200):
            listener=make(socket.AF_INET,socket.SOCK_STREAM);listener.listen()
            client=make(socket.AF_INET,socket.SOCK_STREAM);client.connect(listener.getsockname())
            accepted,_=listener.accept();fixtures.append(accepted)
        for _ in range(200): make(socket.AF_INET,socket.SOCK_DGRAM)
        results['loaded_fixture_socket_count']=len(fixtures)
        results['loaded']=benchmark(30)
    finally:
        for s in fixtures: s.close()
    (ROOT/'results.json').write_text(json.dumps(results,indent=2))
    print(json.dumps(results,indent=2))
if __name__=='__main__':main()
