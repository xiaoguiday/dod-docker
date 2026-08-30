import socket, re, urllib.request, urllib.error
from urllib.parse import urljoin

def ask(prompt, default):
    try:
        v = input(f'{prompt} [{default}]: ').strip()
    except EOFError:
        v = ''
    return v or default

print('=== UPnP 端口映射（可手动输入）===')
ROUTER_IP = ask('路由器网关 IP (留空=SSDP 自动发现)', '192.168.0.1')
EXT_PORT  = ask('外部端口 (对外)', '8443')
INT_PORT  = ask('内部端口 (本机监听)', EXT_PORT)
INT_IP    = ask('内部目标 IP (本机内网 IP)', '192.168.0.4')

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

# 用输入的路由器 IP 直接尝试常见描述路径；留空或不通则回退 SSDP
loc = None
body = None
if ROUTER_IP:
    candidates = [
        f'http://{ROUTER_IP}:1900/rootDesc.xml',
        f'http://{ROUTER_IP}:1900/ziaaw/rootDesc.xml',
        f'http://{ROUTER_IP}:80/rootDesc.xml',
    ]
    for c in candidates:
        try:
            b = urllib.request.urlopen(c, timeout=5).read().decode()
            if 'WANIPConnection' in b or 'InternetGatewayDevice' in b:
                loc, body = c, b
                print('找到 IGD 描述:', loc)
                break
        except Exception:
            continue

if not loc:
    print('用 SSDP 组播自动发现路由器...')
    for d in discover_igd():
        try:
            b = urllib.request.urlopen(d, timeout=5).read().decode()
            if 'WANIPConnection' in b:
                loc, body = d, b
                print('找到 IGD 描述:', loc)
                break
        except Exception:
            continue

if not loc:
    print('错误：找不到路由器的 UPnP IGD 设备，请确认路由器已开启 UPnP。')
    raise SystemExit(1)

m = re.search(r'<serviceType>urn:schemas-upnp-org:service:WANIPConnection:1</serviceType>.*?<controlURL>(.*?)</controlURL>', body, re.S)
ctrl = m.group(1)
stype = 'urn:schemas-upnp-org:service:WANIPConnection:1'
url = urljoin(loc, ctrl)
print('控制地址', url)

def soap(action, args):
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

print('=== GetExternalIPAddress ===')
print(soap('GetExternalIPAddress', {}))
print('=== AddPortMapping %s -> %s:%s ===' % (EXT_PORT, INT_IP, INT_PORT))
print(soap('AddPortMapping', {
    'NewRemoteHost': '',
    'NewExternalPort': EXT_PORT,
    'NewProtocol': 'TCP',
    'NewInternalPort': INT_PORT,
    'NewInternalClient': INT_IP,
    'NewEnabled': '1',
    'NewPortMappingDescription': 'upnp-port-map',
    'NewLeaseDuration': '0',
}))
print('=== verify ===')
print(soap('GetSpecificPortMappingEntry', {
    'NewRemoteHost': '', 'NewExternalPort': EXT_PORT, 'NewProtocol': 'TCP'}))
