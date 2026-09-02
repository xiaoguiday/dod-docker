#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
UPnP 端口映射诊断工具 —— 定位 AddPortMapping 报 501 / 718 / 冲突 等失败原因

用法：
  python3 upnp_diag.py --ext 50006              # 诊断外部端口 50006
  python3 upnp_diag.py --ext 50006 --int 50002  # 外部 50006 -> 内部 50002
  python3 upnp_diag.py --ext 50006 --list-only  # 只列出现有映射，不做添加测试

它会依次：
  1. 查找网关并定位 UPnP IGD
  2. 读取外网 IP
  3. 枚举路由器上【所有已存在的端口映射】（最容易发现端口冲突）
  4. 查询目标端口当前是否被占用
  5. 用 6 种不同参数组合尝试添加，找出你的路由器接受哪一种
纯标准库，兼容 x86/arm、Linux/macOS
"""
import socket, re, subprocess, urllib.request, urllib.error, argparse, sys

STYPE = 'urn:schemas-upnp-org:service:WANIPConnection:1'
STYPE2 = 'urn:schemas-upnp-org:service:WANPPPConnection:1'


def sh(cmd):
    try:
        return subprocess.run(cmd, shell=True, capture_output=True, text=True,
                              encoding='utf-8', errors='replace', timeout=10).stdout
    except Exception:
        return ''


def err_of(xml):
    """从 SOAP 响应里提取错误码与描述"""
    if xml.startswith('HTTP'):
        m = re.search(r'<errorCode>(\d+)</errorCode>', xml)
        d = re.search(r'<errorDescription>(.*?)</errorDescription>', xml, re.S)
        if m:
            return m.group(1), (d.group(1).strip() if d else '')
        return 'HTTP', xml[:120]
    if '<errorCode>' in xml:
        m = re.search(r'<errorCode>(\d+)</errorCode>', xml)
        d = re.search(r'<errorDescription>(.*?)</errorDescription>', xml, re.S)
        return m.group(1), (d.group(1).strip() if d else '')
    return None, ''


def detect_gateways():
    out = sh("ip route show default 2>/dev/null")
    res = []
    for line in out.splitlines():
        m = re.search(r'default(?: via)?\s+(\d+\.\d+\.\d+\.\d+)\s+dev\s+(\S+)\s+(?:.*?metric\s+(\d+))?', line)
        if m:
            res.append({'gw': m.group(1), 'metric': int(m.group(3) or 0)})
    if not res:
        out = sh("route -n get default 2>/dev/null")
        m = re.search(r'gateway:\s+(\d+\.\d+\.\d+\.\d+)', out)
        if m:
            res.append({'gw': m.group(1), 'metric': 0})
    seen, uniq = set(), []
    for r in sorted(res, key=lambda x: x['metric']):
        if r['gw'] in seen:
            continue
        seen.add(r['gw'])
        uniq.append(r)
    return uniq


def detect_local_ip_for(gw):
    out = sh("ip route get %s 2>/dev/null" % gw)
    m = re.search(r'src\s+(\d+\.\d+\.\d+\.\d+)', out)
    if m:
        return m.group(1)
    out = sh('ip -o -4 addr show 2>/dev/null | awk \'$2!="lo"{print $4; exit}\'')
    m = re.search(r'(\d+\.\d+\.\d+\.\d+)', out)
    return m.group(1) if m else ''


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
        for c in ['http://%s:1900/rootDesc.xml' % router_ip,
                  'http://%s:1900/ziaaw/rootDesc.xml' % router_ip,
                  'http://%s:80/rootDesc.xml' % router_ip]:
            try:
                b = urllib.request.urlopen(c, timeout=5).read().decode()
                if 'WANIPConnection' in b or 'WANPPPConnection' in b:
                    return c, b
            except Exception:
                continue
    for d in discover_igd():
        try:
            b = urllib.request.urlopen(d, timeout=5).read().decode()
            if 'WANIPConnection' in b or 'WANPPPConnection' in b:
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
    except Exception as e:
        return 'HTTPERR %s' % e


def main():
    p = argparse.ArgumentParser(description='UPnP 端口映射诊断')
    p.add_argument('--router', default=None, help='网关 IP（默认自动探测）')
    p.add_argument('--ext', default=None, help='要诊断/测试的外部端口')
    p.add_argument('--int', default=None, help='内部端口（默认=外部端口）')
    p.add_argument('--ip', default=None, help='内部 IP（默认自动探测）')
    p.add_argument('--list-only', action='store_true', help='只列出现有映射，不做添加测试')
    args = p.parse_args()

    print('========== UPnP 诊断 ==========')

    # 1. 网关
    gws = [args.router] if args.router else [g['gw'] for g in detect_gateways()]
    if not gws:
        print('[失败] 未发现任何默认路由网关。')
        raise SystemExit(1)
    print('[1] 默认路由网关:', ', '.join(gws))

    router = gws[0]
    int_ip = args.ip or detect_local_ip_for(router)
    print('[1] 本机内网 IP:', int_ip)

    loc, body = find_igd(router)
    if not loc:
        print('[失败] 网关 %s 上找不到 UPnP IGD。' % router)
        raise SystemExit(1)

    # 2. 定位控制 URL 与服务类型
    m = (re.search(r'<serviceType>(urn:schemas-upnp-org:service:WANIPConnection:1)</serviceType>.*?<controlURL>(.*?)</controlURL>', body, re.S)
         or re.search(r'<serviceType>(urn:schemas-upnp-org:service:WANPPPConnection:1)</serviceType>.*?<controlURL>(.*?)</controlURL>', body, re.S))
    if not m:
        print('[失败] rootDesc.xml 里没有 WANIPConnection / WANPPPConnection 服务。')
        raise SystemExit(1)
    stype, ctrl = m.group(1), m.group(2)
    from urllib.parse import urljoin
    url = urljoin(loc, ctrl)
    print('[2] 服务类型:', stype)
    print('[2] 控制地址:', url)

    def soap(action, a):
        return build_soap(stype, url, action, a)

    # 3. 外网 IP
    r = soap('GetExternalIPAddress', {})
    ipm = re.search(r'<NewExternalIPAddress>(.*?)</NewExternalIPAddress>', r)
    print('[3] 外网 IP:', ipm.group(1) if ipm else '获取失败')

    # 4. 枚举现有映射
    print('\n[4] 路由器上已存在的端口映射：')
    existing = []
    print('    %-10s %-6s %-18s %-8s %s' % ('外部端口', '协议', '内部地址', '租约', '描述'))
    print('    ' + '-' * 68)
    for i in range(0, 200):
        rr = soap('GetGenericPortMappingEntry', {'NewPortMappingIndex': i})
        if '<errorCode>' in rr or rr.startswith('HTTP'):
            break
        ep = re.search(r'<NewExternalPort>(.*?)</NewExternalPort>', rr)
        pr = re.search(r'<NewProtocol>(.*?)</NewProtocol>', rr)
        ic = re.search(r'<NewInternalClient>(.*?)</NewInternalClient>', rr)
        ipo = re.search(r'<NewInternalPort>(.*?)</NewInternalPort>', rr)
        de = re.search(r'<NewPortMappingDescription>(.*?)</NewPortMappingDescription>', rr)
        du = re.search(r'<NewLeaseDuration>(.*?)</NewLeaseDuration>', rr)
        if not ep:
            break
        item = {'ext': ep.group(1), 'proto': pr.group(1) if pr else '?',
                'client': ic.group(1) if ic else '?', 'int': ipo.group(1) if ipo else '?',
                'desc': de.group(1) if de else '', 'lease': du.group(1) if du else '?'}
        existing.append(item)
        flag = ''
        if args.ext and item['ext'] == str(args.ext):
            flag = '   <<<< 端口冲突！'
        if item['client'] == int_ip:
            flag += ' [本机]'
        print('    %-10s %-6s %-18s %-8s %s%s' % (
            item['ext'], item['proto'], item['client'] + ':' + item['int'],
            item['lease'], item['desc'][:22], flag))
    print('    共 %d 条' % len(existing))

    if args.list_only:
        return

    if not args.ext:
        print('\n[提示] 未指定 --ext，跳过添加测试。加 --ext 端口号 做添加测试。')
        return

    ext = str(args.ext)
    intp = str(args.int or args.ext)

    # 5. 目标端口占用查询
    print('\n[5] 查询外部端口 %s 当前是否被占用：' % ext)
    rr = soap('GetSpecificPortMappingEntry',
              {'NewRemoteHost': '', 'NewExternalPort': ext, 'NewProtocol': 'TCP'})
    c, d = err_of(rr)
    if c:
        print('    未被占用（返回 %s %s = 查不到该映射）' % (c, d))
    else:
        ic = re.search(r'<NewInternalClient>(.*?)</NewInternalClient>', rr)
        ipo = re.search(r'<NewInternalPort>(.*?)</NewInternalPort>', rr)
        print('    [已被占用] -> %s:%s' % (ic.group(1) if ic else '?', ipo.group(1) if ipo else '?'))

    # 6. 多组参数尝试
    print('\n[6] 尝试不同的 AddPortMapping 参数组合（找出路由器接受哪种）：')
    combos = [
        ('A 标准：RemoteHost="" + 租约0 + 描述upnp-port-map',
         {'NewRemoteHost': '', 'NewExternalPort': ext, 'NewProtocol': 'TCP',
          'NewInternalPort': intp, 'NewInternalClient': int_ip, 'NewEnabled': '1',
          'NewPortMappingDescription': 'upnp-port-map', 'NewLeaseDuration': '0'}),
        ('B 省略 NewRemoteHost',
         {'NewExternalPort': ext, 'NewProtocol': 'TCP',
          'NewInternalPort': intp, 'NewInternalClient': int_ip, 'NewEnabled': '1',
          'NewPortMappingDescription': 'upnp-port-map', 'NewLeaseDuration': '0'}),
        ('C 租约 3600 秒（不用 0）',
         {'NewRemoteHost': '', 'NewExternalPort': ext, 'NewProtocol': 'TCP',
          'NewInternalPort': intp, 'NewInternalClient': int_ip, 'NewEnabled': '1',
          'NewPortMappingDescription': 'upnp-port-map', 'NewLeaseDuration': '3600'}),
        ('D 描述简化为 upnp',
         {'NewRemoteHost': '', 'NewExternalPort': ext, 'NewProtocol': 'TCP',
          'NewInternalPort': intp, 'NewInternalClient': int_ip, 'NewEnabled': '1',
          'NewPortMappingDescription': 'upnp', 'NewLeaseDuration': '0'}),
        ('E 省略 RemoteHost + 租约3600 + 简短描述',
         {'NewExternalPort': ext, 'NewProtocol': 'TCP',
          'NewInternalPort': intp, 'NewInternalClient': int_ip, 'NewEnabled': '1',
          'NewPortMappingDescription': 'upnp', 'NewLeaseDuration': '3600'}),
        ('F 协议改用 UDP（测试端口是否被策略禁止）',
         {'NewRemoteHost': '', 'NewExternalPort': ext, 'NewProtocol': 'UDP',
          'NewInternalPort': intp, 'NewInternalClient': int_ip, 'NewEnabled': '1',
          'NewPortMappingDescription': 'upnp', 'NewLeaseDuration': '0'}),
    ]
    worked = None
    for name, a in combos:
        rr = soap('AddPortMapping', a)
        c, d = err_of(rr)
        if c:
            print('    [X] %-46s -> %s %s' % (name, c, d))
        else:
            print('    [√] %-46s -> 成功' % name)
            if worked is None:
                worked = (name, a)
            # 清理这条测试映射
            soap('DeletePortMapping', {'NewRemoteHost': '', 'NewExternalPort': ext,
                                       'NewProtocol': a.get('NewProtocol', 'TCP')})
    if not worked:
        # 换端口再试，判断是端口问题还是参数问题
        alt = str(int(ext) + 1)
        print('\n    --- 换一个端口 %s 再试（判断是端口本身被拒，还是参数不被接受）---' % alt)
        a = {'NewRemoteHost': '', 'NewExternalPort': alt, 'NewProtocol': 'TCP',
             'NewInternalPort': intp, 'NewInternalClient': int_ip, 'NewEnabled': '1',
             'NewPortMappingDescription': 'upnp', 'NewLeaseDuration': '0'}
        rr = soap('AddPortMapping', a)
        c, d = err_of(rr)
        if c:
            print('    [X] 端口 %s 也失败（%s %s）-> 是路由器拒绝这台主机的 UPnP 请求' % (alt, c, d))
        else:
            print('    [√] 端口 %s 成功 -> 说明端口 %s 被路由器策略禁止（常见于高位端口/运营商封堵）' % (alt, ext))
            soap('DeletePortMapping', {'NewRemoteHost': '', 'NewExternalPort': alt, 'NewProtocol': 'TCP'})

    print('\n========== 结论 ==========')
    if worked:
        print('可用组合：%s' % worked[0])
        print('建议用对应参数重跑主脚本。')
    else:
        print('全部组合失败。常见原因：')
        print(' 1. 路由器【UPnP 开关已开但禁止新增】，或需要 Web 管理界面里勾选"允许 UPnP 添加映射"')
        print(' 2. 运营商光猫处于路由模式且被远程管控（部分省市会封禁 UPnP）')
        print(' 3. 该端口被路由器自身服务占用（远程管理/DMZ/虚拟服务器）')
        print(' 4. 内网 IP 不在路由器 DHCP 池 / 被 MAC 过滤')
        print(' 5. 路由器 UPnP 实现有 bug，重启路由器后再试')


if __name__ == '__main__':
    main()
