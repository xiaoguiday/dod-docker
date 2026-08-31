#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
UPnP 端口映射 + 自动保活（支持多网卡 / 双 WAN）
  --auto : 自动枚举所有默认路由网关，逐个探测 UPnP，用各自网卡的 IP 做 internal client
  -d     : 映射后直接转入后台保活（无交互），周期性刷新租约防止路由器回收
  交互运行（不带 -d）时，会询问是否启用后台保活，并让你设定间隔（默认 1 小时）
  纯标准库，兼容 x86/arm、Linux/macOS
"""
import socket, re, subprocess, urllib.request, urllib.error, time, argparse, sys, os
from urllib.parse import urljoin

def ask(prompt, default):
    try:
        v = input(f'{prompt} [{default}]: ').strip()
    except EOFError:
        v = ''
    return v or default

def ok(xml):
    if xml.startswith('HTTP'):
        return False, xml
    if '<errorCode>' in xml:
        c = re.search(r'<errorCode>(\d+)</errorCode>', xml)
        d = re.search(r'<errorDescription>(.*?)</errorDescription>', xml, re.S)
        return False, f'errorCode={c.group(1) if c else "?"} {d.group(1).strip() if d else ""}'
    return True, ''

def run(cmd):
    try:
        return subprocess.run(cmd, shell=True, capture_output=True, text=True,
                              encoding='utf-8', errors='replace', timeout=10).stdout
    except Exception:
        return ''

# ---------- 网络探测（支持多网卡/双 WAN） ----------
def detect_gateways():
    """返回所有默认路由网关 [{gw, iface, metric}]，按 metric 升序（优先路由在前）"""
    out = run("ip route show default 2>/dev/null")
    res = []
    for line in out.splitlines():
        m = re.search(r'default(?: via)?\s+(\d+\.\d+\.\d+\.\d+)\s+dev\s+(\S+)\s+(?:.*?metric\s+(\d+))?', line)
        if m:
            res.append({'gw': m.group(1), 'iface': m.group(2), 'metric': int(m.group(3) or 0)})
    if not res:  # macOS
        out = run("route -n get default 2>/dev/null")
        m = re.search(r'gateway:\s+(\d+\.\d+\.\d+\.\d+)', out)
        if m:
            res.append({'gw': m.group(1), 'iface': '', 'metric': 0})
    seen, uniq = set(), []
    for r in sorted(res, key=lambda x: x['metric']):
        if r['gw'] in seen:
            continue
        seen.add(r['gw'])
        uniq.append(r)
    return uniq

def detect_local_ip_for(gw):
    if gw:
        out = run(f"ip route get {gw} 2>/dev/null")
        m = re.search(r'src\s+(\d+\.\d+\.\d+\.\d+)', out)
        if m:
            return m.group(1)
    out = run("ip -o -4 addr show 2>/dev/null | awk '$2!=\"lo\"{print $4; exit}'")
    m = re.search(r'(\d+\.\d+\.\d+\.\d+)', out)
    return m.group(1) if m else ''

def detect_listen_port(proc_hint='sing-box'):
    out = run(f"ss -tlnp 2>/dev/null | grep -i '{proc_hint}'")
    if not out:
        out = run(f"netstat -tlnp 2>/dev/null | grep -i '{proc_hint}'")
    ports = re.findall(r':(\d+)\s', out)
    if ports:
        return ports[0]
    out = run("ss -tlnp 2>/dev/null") or run("netstat -tlnp 2>/dev/null")
    nums = [int(p) for p in re.findall(r':(\d+)\s', out) if p.isdigit()]
    return str(max(nums)) if nums else ''

# ---------- UPnP 发现 ----------
def discover_igd():
    req = ('M-SEARCH * HTTP/1.1\r\nHOST: 239.255.255.250:1900\r\n'
           'MAN: "ssdp:discover"\r\nMX: 3\r\n'
           'ST: urn:schemas-upnp-org:device:InternetGatewayDevice:1\r\n\r\n')
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    s.settimeout(5)
    s.sendto(req.encode(), ('239.255.255.250', 1900))
    found = []
    try:
        while True:
            data, addr = s.recvfrom(4096)
            loc = re.search(r'LOCATION:\s*(\S+)', data.decode(errors='ignore'), re.I)
            if loc:
                found.append(loc.group(1))
    except socket.timeout:
        pass
    s.close()
    return found

def find_igd(router_ip):
    if router_ip:
        for c in [
            f'http://{router_ip}:1900/rootDesc.xml',
            f'http://{router_ip}:1900/ziaaw/rootDesc.xml',
            f'http://{router_ip}:80/rootDesc.xml',
        ]:
            try:
                b = urllib.request.urlopen(c, timeout=5).read().decode()
                if 'WANIPConnection' in b or 'InternetGatewayDevice' in b:
                    return c, b
            except Exception:
                continue
    for d in discover_igd():
        try:
            b = urllib.request.urlopen(d, timeout=5).read().decode()
            if 'WANIPConnection' in b:
                return d, b
        except Exception:
            continue
    return None, None

def build_soap(stype, url, action, args):
    a = ''.join('<%s>%s</%s>' % (k, v, k) for k, v in args.items())
    payload = ('<?xml version="1.0"?>'
               '<s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" '
               's:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/">'
               '<s:Body><u:%s xmlns:u="%s">%s</u:%s></s:Body></s:Envelope>'
               % (action, stype, a, action))
    req = urllib.request.Request(url)
    req.add_header('Content-Type', 'text/xml; charset="utf-8"')
    req.add_header('SOAPACTION', '"%s#%s"' % (stype, action))
    try:
        return urllib.request.urlopen(req, data=payload.encode(), timeout=8).read().decode()
    except urllib.error.HTTPError as e:
        return 'HTTP%d %s' % (e.code, e.read().decode(errors='ignore'))

def make_client(loc, body, ext_port, int_port, int_ip):
    m = re.search(r'<serviceType>urn:schemas-upnp-org:service:WANIPConnection:1</serviceType>.*?<controlURL>(.*?)</controlURL>', body, re.S)
    ctrl = m.group(1)
    stype = 'urn:schemas-upnp-org:service:WANIPConnection:1'
    url = urljoin(loc, ctrl)

    def soap(action, a):
        return build_soap(stype, url, action, a)

    def add_mapping():
        r = soap('AddPortMapping', {
            'NewRemoteHost': '', 'NewExternalPort': ext_port, 'NewProtocol': 'TCP',
            'NewInternalPort': int_port, 'NewInternalClient': int_ip,
            'NewEnabled': '1', 'NewPortMappingDescription': 'upnp-port-map',
            'NewLeaseDuration': '0',
        })
        g, err = ok(r)
        if not g:
            print(f'  [失败] 添加失败: {err}'); return False
        r = soap('GetSpecificPortMappingEntry', {
            'NewRemoteHost': '', 'NewExternalPort': ext_port, 'NewProtocol': 'TCP'})
        g, err = ok(r)
        if not g:
            print(f'  [失败] 校验失败: {err}'); return False
        cip = re.search(r'<NewInternalClient>(.*?)</NewInternalClient>', r)
        cport = re.search(r'<NewInternalPort>(.*?)</NewInternalPort>', r)
        cena = re.search(r'<NewEnabled>(.*?)</NewEnabled>', r)
        cdur = re.search(r'<NewLeaseDuration>(.*?)</NewLeaseDuration>', r)
        dur = '永久' if (cdur and cdur.group(1) == '0') else (cdur.group(1) + '秒' if cdur else '?')
        if cip and cip.group(1) == int_ip and cport and cport.group(1) == int_port:
            print(f'  [OK] 映射有效: 外部 {ext_port} -> {int_ip}:{cport.group(1)} (启用={cena.group(1) if cena else "?"}, 租约={dur})')
            return True
        print(f'  [警告] 校验不一致: {cip.group(1) if cip else "?"}:{cport.group(1) if cport else "?"}')
        return True
    return url, add_mapping, soap

# ---------- 后台保活（daemonize） ----------
def keepalive_loop(clients, renew):
    print('==== 后台保活启动：每 %d 秒刷新所有网关租约 ====' % renew)
    while True:
        time.sleep(renew)
        ts = time.strftime('%Y-%m-%d %H:%M:%S')
        for router, int_ip, add_mapping in clients:
            tag = '[%s] 网关 %s' % (ts, router)
            if add_mapping():
                print(tag + ' [OK] 已刷新')
            else:
                print(tag + ' [!] 刷新失败，下次重试')

def daemonize_and_run(renew, clients, logfile):
    pid = os.fork()
    if pid > 0:
        print('已转入后台保活，日志:', logfile)
        print('查看: tail -f', logfile, '| 停止: pkill -f upnp_port.py')
        return
    os.setsid()
    pid = os.fork()
    if pid > 0:
        os._exit(0)
    sys.stdout.flush()
    sys.stderr.flush()
    try:
        dn = open(os.devnull)
        os.dup2(dn.fileno(), 0)
        logf = open(logfile, 'a')
        os.dup2(logf.fileno(), 1)
        os.dup2(logf.fileno(), 2)
    except Exception:
        pass
    keepalive_loop(clients, renew)
    os._exit(0)

def main():
    p = argparse.ArgumentParser(description='UPnP 端口映射 + 自动保活（支持多网卡/双WAN）')
    p.add_argument('--auto', action='store_true', help='自动枚举所有网关/网卡IP/代理端口')
    p.add_argument('--router', default=None, help='仅用此网关（默认对所有默认路由网关）')
    p.add_argument('--ext', default=None, help='外部端口')
    p.add_argument('--int-port', default=None, help='内部端口（默认=外部端口）')
    p.add_argument('--int-ip', default=None, help='内部目标 IP（默认=自动探测对应网卡IP）')
    p.add_argument('--port', default=None, help='内外统一端口')
    p.add_argument('--proc', default='sing-box', help='自动探测端口时匹配的进程名')
    p.add_argument('--renew', type=int, default=3600, help='保活间隔秒（默认 3600=1小时）')
    p.add_argument('-d', '--daemon', action='store_true', help='映射后直接转入后台保活（无交互）')
    p.add_argument('--log', default='/var/log/upnp_port.log', help='后台保活日志文件路径')
    args = p.parse_args()

    print('=== UPnP 端口映射（支持多网卡/双 WAN）===')

    EXT_PORT = args.port or args.ext
    INT_PORT = args.int_port
    DETECTED_PORT = None
    if args.auto and not EXT_PORT:
        DETECTED_PORT = detect_listen_port(args.proc)
        print('[自动] 探测到的代理监听端口:', DETECTED_PORT or '(未探测到)')

    targets = []
    if args.router:
        gws = [{'gw': args.router, 'iface': '', 'metric': 0}]
    elif args.auto:
        gws = detect_gateways()
        print(f'[自动] 发现 {len(gws)} 条默认路由:', ', '.join(g["gw"] for g in gws) or '(无)')
    else:
        gws = []

    if gws:
        for g in gws:
            lip = args.int_ip or detect_local_ip_for(g['gw'])
            loc, body = find_igd(g['gw'])
            if loc:
                targets.append({'router': g['gw'], 'int_ip': lip, 'loc': loc, 'body': body})
                print(f'[OK] 网关 {g["gw"]} 有 UPnP IGD（网卡IP={lip}）')
            else:
                print(f'[跳过] 网关 {g["gw"]} 无 UPnP（未开启或不可达）')
    else:
        if args.auto:
            print('[失败] --auto 模式下未发现任何默认路由网关，无法自动映射。')
            raise SystemExit(1)
        ROUTER_IP = ask('路由器网关 IP (留空=SSDP 自动发现)', '192.168.0.1')
        EXT_PORT = EXT_PORT or ask('外部端口 (对外)', '8443')
        INT_PORT = INT_PORT or ask('内部端口 (本机监听)', EXT_PORT)
        lip = args.int_ip or detect_local_ip_for(ROUTER_IP)
        loc, body = find_igd(ROUTER_IP)
        if loc:
            targets.append({'router': ROUTER_IP, 'int_ip': lip, 'loc': loc, 'body': body})
        else:
            print('[失败] 找不到路由器的 UPnP IGD 设备，请确认路由器已开启 UPnP。')
            raise SystemExit(1)

    if not targets:
        print('[失败] 没有任何可用网关具备 UPnP，无法映射。')
        raise SystemExit(1)

    if not EXT_PORT:
        EXT_PORT = ask('外部端口 (对外)', DETECTED_PORT or '8443')
    if not INT_PORT:
        INT_PORT = EXT_PORT if args.auto else ask('内部端口 (本机监听)', EXT_PORT)
    EXT_PORT, INT_PORT = str(EXT_PORT), str(INT_PORT)

    clients = []
    for t in targets:
        int_ip = t['int_ip'] or detect_local_ip_for(t['router'])
        url, add_mapping, soap = make_client(t['loc'], t['body'], EXT_PORT, INT_PORT, int_ip)
        print(f'-- 网关 {t["router"]} 控制地址: {url} (internal={int_ip})')
        r = soap('GetExternalIPAddress', {})
        g, err = ok(r)
        if g:
            ip = re.search(r'<NewExternalIPAddress>(.*?)</NewExternalIPAddress>', r)
            print(f'   [OK] 外网 IP: {ip.group(1) if ip else "?"}')
        else:
            print(f'   [信息] 获取外网 IP 失败（不影响映射）: {err}')
        clients.append((t['router'], int_ip, add_mapping))

    ok_all = True
    for router, int_ip, add_mapping in clients:
        print(f'>> 映射 网关 {router} (内网 {int_ip}:{INT_PORT})')
        if not add_mapping():
            ok_all = False
    if not ok_all:
        raise SystemExit(1)

    if args.daemon:
        daemonize_and_run(args.renew, clients, args.log)
        return

    yn = ask('是否启用后台保活（防止路由器回收映射）?', 'n')
    if str(yn).strip().lower() in ('y', 'yes', '是'):
        iv = ask('保活间隔（秒，直接回车默认 1 小时）', '3600')
        try:
            interval = int(iv)
        except ValueError:
            interval = 3600
        if interval < 30:
            interval = 30
        daemonize_and_run(interval, clients, args.log)
        return

    print('==== 映射已添加（未启用保活）====')

if __name__ == '__main__':
    main()
