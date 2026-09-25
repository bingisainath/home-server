#!/bin/bash
# Routing checks for nginx/pocket.conf. Run as your normal user: bash scripts/test-routing.sh [ip]   (default 127.0.0.1; try the Tailscale IP too)
IP=${1:-127.0.0.1}
pass=0; fail=0
check() { # name expected actual
  if [ "$2" = "$3" ]; then echo "PASS  $1"; pass=$((pass+1)); else echo "FAIL  $1 (expected $2, got $3)"; fail=$((fail+1)); fi
}
code() { curl -s -o /dev/null -m 10 -w '%{http_code}' "$@"; }

check "portfolio home"                 200 "$(code --resolve bingisainath.com:80:$IP http://bingisainath.com/)"
check "portfolio SPA route /project/1" 200 "$(code --resolve bingisainath.com:80:$IP http://bingisainath.com/project/1)"
check "portfolio missing asset -> 404" 404 "$(code --resolve bingisainath.com:80:$IP http://bingisainath.com/assets/nope.js)"
check "portfolio dotfile blocked"      403 "$(code --resolve bingisainath.com:80:$IP http://bingisainath.com/.git/config)" 
check "drive health via nginx"         200 "$(code --resolve drive.bingisainath.com:80:$IP http://drive.bingisainath.com/api/health)"
check "drive SPA shell"                200 "$(code --resolve drive.bingisainath.com:80:$IP http://drive.bingisainath.com/)"
check "drive API needs auth (401)"     401 "$(code --resolve drive.bingisainath.com:80:$IP http://drive.bingisainath.com/api/files)"
check "unknown host dropped"           000 "$(code -H 'Host: evil.example' http://$IP/)"

# Upload size limit: a 20 MB body must reach the app (401 = app answered, not nginx 413); 101 MB must be refused by nginx.
head -c 20971520  /dev/zero > /tmp/pd-20mb.bin
head -c 105906176 /dev/zero > /tmp/pd-101mb.bin
c20=$(code -X PUT --data-binary @/tmp/pd-20mb.bin  -H 'Content-Type: application/octet-stream' --resolve drive.bingisainath.com:80:$IP http://drive.bingisainath.com/api/uploads/x)
# 401 = app answered. 502 can also occur: the app rejects an unauthenticated chunk without reading it and closes the
# connection while nginx is still streaming (known race, see README). Either way nginx itself did not refuse the size.
[ "$c20" = 401 ] || [ "$c20" = 502 ] && c20=reached-app
check "20 MB chunk not refused by nginx" reached-app "$c20"
check "101 MB chunk refused (413)"     413 "$(code -X PUT --data-binary @/tmp/pd-101mb.bin -H 'Content-Type: application/octet-stream' --resolve drive.bingisainath.com:80:$IP http://drive.bingisainath.com/api/uploads/x)"
rm -f /tmp/pd-20mb.bin /tmp/pd-101mb.bin

# Proxy-header trust. The OAuth start route sets a cookie whose Secure flag follows what the app believes the scheme is.
NONLOOP=$(hostname -I | tr " " "\n" | grep -v "^127\." | head -1)   # a real address of this machine: not trusted like loopback
COOKIE_URL="api/auth/google/start?origin=https://drive.bingisainath.com"
secure_flag() { curl -s -o /dev/null -D - -m 10 "$@" | grep -i '^set-cookie: cd_oauth' | grep -qi '; secure' && echo secure || echo insecure; }
check "forged X-Forwarded-Proto from network ignored" insecure "$(secure_flag --resolve drive.bingisainath.com:80:$NONLOOP -H 'X-Forwarded-Proto: https' -H 'CF-Connecting-IP: 1.2.3.4' http://drive.bingisainath.com/$COOKIE_URL)"
check "https from loopback (tunnel) honoured"          secure   "$(secure_flag --resolve drive.bingisainath.com:80:127.0.0.1 -H 'X-Forwarded-Proto: https' -H 'CF-Connecting-IP: 1.2.3.4' http://drive.bingisainath.com/$COOKIE_URL)"

echo "-- headers on drive response:"; curl -sI -m 10 --resolve drive.bingisainath.com:80:$IP http://drive.bingisainath.com/ | grep -iE '^(HTTP|server|cache-control|content-security)' 
echo; echo "$pass passed, $fail failed"; [ "$fail" = 0 ]
