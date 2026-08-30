```python
# -*- coding: utf-8 -*-

import socket
import re
import urllib
import urllib2
from urlparse import urljoin

def ask(prompt, default):
    try:
        v = raw_input('%s [%s]: ' % (prompt, default)).strip()
    except (EOFError, KeyboardInterrupt):
        v = ''
    return v or default


def parse_error(xml):
    if not xml:
        return '未知错误'

    code = re.search(r'<errorCode>\s*(\d+)\s*</errorCode>', xml, re.I)
    desc = re.search(r'<errorDescription>\s*(.*?)\s*</errorDescription>', xml, re.I | re.S)

    if code:
        return 'errorCode=%s %s' % (
            code.group(1),
            desc.group(1).strip() if desc else ''
        )

    return xml[:500]


print('======================================')
print('       UPnP 端口映射工具')
print('       Python 2.7 兼容版')
print('======================================')

ROUTER_IP = ask('路由器网关 IP (留空=SSDP 自动发现)', '192.168.0.1')
EXT_PORT = ask('外部端口 (对外)', '8443')
INT_PORT = ask('内部端口 (本机监听)', EXT_PORT)
INT_IP = ask('内部目标 IP', '192.168.0.4')
PROTOCOL = ask('协议 TCP/UDP', 'TCP').upper()

if PROTOCOL not in ('TCP', 'UDP'):
    print('协议错误，只能输入 TCP 或 UDP')
    raise SystemExit(1)


# ======================================
# SSDP 自动发现
# ======================================

def discover_igd():

    req = (
        'M-SEARCH * HTTP/1.1\r\n'
        'HOST: 239.255.255.250:1900\r\n'
        'MAN: "ssdp:discover"\r\n'
        'MX: 3\r\n'
        'ST: urn:schemas-upnp-org:device:InternetGatewayDevice:1\r\n'
        '\r\n'
    )

    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    s.setsockopt(socket.SOL_SOCKET, socket.SO_BROADCAST, 1)
    s.settimeout(5)

    try:
        s.sendto(req, ('239.255.255.250', 1900))
    except Exception as e:
        print('SSDP 发送失败:', e)
        s.close()
        return []

    found = []

    while True:
        try:
            data, addr = s.recvfrom(8192)

            text = data.decode('utf-8', 'ignore')

            m = re.search(
                r'LOCATION:\s*(\S+)',
                text,
                re.I
            )

            if m:
                loc = m.group(1)

                if loc not in found:
                    found.append(loc)
                    print('发现 UPnP:', loc)

        except socket.timeout:
            break
        except Exception:
            break

    s.close()

    return found


# ======================================
# 获取 IGD 描述文件
# ======================================

loc = None
body = None

if ROUTER_IP:

    candidates = [
        'http://%s/rootDesc.xml' % ROUTER_IP,
        'http://%s:80/rootDesc.xml' % ROUTER_IP,
        'http://%s:1900/rootDesc.xml' % ROUTER_IP,
        'http://%s/igd.xml' % ROUTER_IP,
    ]

    print('')
    print('尝试直接寻找路由器 UPnP 描述文件...')

    for c in candidates:

        try:
            print('尝试:', c)

            req = urllib2.Request(c)
            response = urllib2.urlopen(req, timeout=5)
            b = response.read()

            if 'InternetGatewayDevice' in b or 'WANIPConnection' in b:
                loc = c
                body = b

                print('[OK] 找到 IGD 描述:', loc)
                break

        except Exception as e:
            pass


# ======================================
# SSDP
# ======================================

if not loc:

    print('')
    print('直接访问失败，使用 SSDP 自动发现...')

    devices = discover_igd()

    for d in devices:

        try:
            response = urllib2.urlopen(d, timeout=5)
            b = response.read()

            if 'InternetGatewayDevice' in b or 'WANIPConnection' in b:

                loc = d
                body = b

                print('[OK] 找到 IGD 描述:', loc)
                break

        except Exception:
            continue


if not loc:

    print('')
    print('[失败] 找不到 UPnP IGD。')
    print('')
    print('请检查：')
    print('1. 路由器是否开启 UPnP')
    print('2. 群晖和路由器是否在同一个局域网')
    print('3. Docker/虚拟网络是否影响 SSDP')
    raise SystemExit(1)


# ======================================
# 查找 WANIPConnection
# ======================================

service_types = [
    'urn:schemas-upnp-org:service:WANIPConnection:2',
    'urn:schemas-upnp-org:service:WANIPConnection:1'
]

stype = None
ctrl = None

for service_type in service_types:

    pattern = (
        r'<serviceType>\s*%s\s*</serviceType>'
        r'.*?'
        r'<controlURL>\s*(.*?)\s*</controlURL>'
    ) % re.escape(service_type)

    m = re.search(pattern, body, re.I | re.S)

    if m:

        stype = service_type
        ctrl = m.group(1).strip()

        break


if not stype:

    print('')
    print('[失败] 找不到 WANIPConnection 服务。')
    print('')
    print('路由器返回的描述文件中没有找到：')
    print('WANIPConnection:1')
    print('WANIPConnection:2')
    raise SystemExit(1)


url = urljoin(loc, ctrl)

print('')
print('UPnP Service :', stype)
print('Control URL  :', url)


# ======================================
# SOAP
# ======================================

def soap(action, args):

    elements = []

    for key, value in args.items():

        if value is None:
            value = ''

        value = str(value)

        # XML 转义
        value = value.replace('&', '&amp;')
        value = value.replace('<', '&lt;')
        value = value.replace('>', '&gt;')
        value = value.replace('"', '&quot;')
        value = value.replace("'", '&apos;')

        elements.append(
            '<%s>%s</%s>' % (
                key,
                value,
                key
            )
        )

    payload = (
        '<?xml version="1.0"?>'
        '<s:Envelope '
        'xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" '
        's:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/">'
        '<s:Body>'
        '<u:%s xmlns:u="%s">'
        '%s'
        '</u:%s>'
        '</s:Body>'
        '</s:Envelope>'
    ) % (
        action,
        stype,
        ''.join(elements),
        action
    )

    req = urllib2.Request(url)

    req.add_header(
        'Content-Type',
        'text/xml; charset="utf-8"'
    )

    req.add_header(
        'SOAPACTION',
        '"%s#%s"' % (stype, action)
    )

    try:

        response = urllib2.urlopen(
            req,
            payload,
            timeout=10
        )

        return response.read()

    except urllib2.HTTPError as e:

        data = e.read()

        return 'HTTP%d %s' % (
            e.code,
            data
        )

    except Exception as e:

        return 'ERROR %s' % str(e)


# ======================================
# 获取公网 IP
# ======================================

print('')
print('======================================')
print('GetExternalIPAddress')
print('======================================')

r = soap(
    'GetExternalIPAddress',
    {}
)

if r.startswith('HTTP') or r.startswith('ERROR'):

    print('[信息] 获取公网 IP 失败:')
    print(parse_error(r))

else:

    m = re.search(
        r'<NewExternalIPAddress>\s*(.*?)\s*</NewExternalIPAddress>',
        r,
        re.I
    )

    if m:
        print('[OK] 路由器公网 IP:', m.group(1))
    else:
        print(r)


# ======================================
# 检查当前端口映射
# ======================================

print('')
print('======================================')
print('检查现有端口映射')
print('======================================')

r = soap(
    'GetSpecificPortMappingEntry',
    {
        'NewRemoteHost': '',
        'NewExternalPort': EXT_PORT,
        'NewProtocol': PROTOCOL
    }
)

if r.startswith('HTTP') or r.startswith('ERROR'):

    print('当前没有找到相同端口映射，继续添加。')

else:

    print('[警告] 这个端口已经存在映射：')
    print(r)

    answer = ask(
        '是否继续覆盖/更新？ Y/N',
        'Y'
    ).upper()

    if answer != 'Y':
        print('已取消。')
        raise SystemExit(0)


# ======================================
# 添加端口映射
# ======================================

print('')
print('======================================')
print('AddPortMapping')
print('======================================')

print(
    '外部 %s/%s -> %s:%s'
    % (
        EXT_PORT,
        PROTOCOL,
        INT_IP,
        INT_PORT
    )
)

r = soap(
    'AddPortMapping',
    {
        'NewRemoteHost': '',
        'NewExternalPort': EXT_PORT,
        'NewProtocol': PROTOCOL,
        'NewInternalPort': INT_PORT,
        'NewInternalClient': INT_IP,
        'NewEnabled': '1',
        'NewPortMappingDescription': 'upnp-port-map',
        'NewLeaseDuration': '0'
    }
)

if r.startswith('HTTP') or r.startswith('ERROR'):

    print('')
    print('[失败] 端口映射添加失败')
    print('--------------------------------------')
    print(parse_error(r))
    print('--------------------------------------')
    print('')
    print('原始返回：')
    print(r)

    raise SystemExit(1)


print('[OK] 路由器接受端口映射请求。')


# ======================================
# 验证
# ======================================

print('')
print('======================================')
print('验证端口映射')
print('======================================')

r = soap(
    'GetSpecificPortMappingEntry',
    {
        'NewRemoteHost': '',
        'NewExternalPort': EXT_PORT,
        'NewProtocol': PROTOCOL
    }
)

if r.startswith('HTTP') or r.startswith('ERROR'):

    print('[失败] 验证失败:')
    print(parse_error(r))

else:

    print('[OK] 路由器返回映射信息：')
    print(r)

    m1 = re.search(
        r'<NewInternalClient>\s*(.*?)\s*</NewInternalClient>',
        r,
        re.I
    )

    m2 = re.search(
        r'<NewInternalPort>\s*(.*?)\s*</NewInternalPort>',
        r,
        re.I
    )

    if m1 and m2:

        print('')
        print('======================================')
        print('端口映射已生效')
        print('======================================')
        print(
            '公网 %s/%s'
            ' -> '
            '%s:%s'
            % (
                EXT_PORT,
                PROTOCOL,
                m1.group(1),
                m2.group(1)
            )
        )
    else:

        print('[警告] 路由器返回的数据无法解析。')
```
