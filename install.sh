#!/bin/sh
# Instalador do servidor Arca Backup para Linux.
# Uso: sudo sh install.sh [--admin-password 'SENHA'] [--timezone America/Fortaleza] [--porta 8443] [--desinstalar [--apagar-dados]]
# Baixa só o programa do processador deste servidor e confere o SHA256. Precisa de curl ou wget, gzip e sha256sum.
set -eu
# Valores preenchidos por montar.sh
SHA_amd64=7159e5175487ca5e2e2eb956962fbc4455d840b2c0fe30d2e451c5bf31251b78
SHA_arm64=07f0adb44685981020ff9e85ab98720ee35eee7052e0df39ca41a05686c53448
SHA_arm=2235194a318667f00e866595395275f02c79485d86bfed61ac2953abaace6899
SHA_386=6bdf5729902c58353ffcf78b25f82dd32498b45f8bd07a1ca2ddc4e9ba41c956
SHA_ppc64le=78d04feb4c2459d730912f38d0908777e2906777ddd4ac64f925d860a356cab9
SHA_s390x=af1fa3320874770446393b7cafd8d8f468a4277bfa3cad3a45c5616b021b779f
SHA_riscv64=10c72af11647371db308c9f3316556620dca50d8e2f06725ad603da9d837a6f5
URL_BASE=${ARCA_URL_BASE:-https://raw.githubusercontent.com/saulosilva85/rclone/atualizacoes}
ATUALIZADOR=/usr/local/bin/arca-atualizar
PORTA=""; REMOVER=0; APAGAR=0; SENHA_INFORMADA=""; FUSO=""
BASE=/opt/arca; DADOS=/var/lib/arca; LOGF=/var/log/arca.log; CONTA=arca; BIN=$BASE/arca-servidor
msg(){ printf '%s\n' "$*"; }
ok(){ printf '  OK  %s\n' "$*"; }
falha(){ printf 'ERRO: %s\n' "$*" >&2; exit 1; }
tem(){ command -v "$1" >/dev/null 2>&1; }
while [ $# -gt 0 ]; do
  case "$1" in
    --porta) [ $# -ge 2 ] || falha "--porta precisa de um número"; PORTA=$2; shift 2;;
    --admin-password) [ $# -ge 2 ] || falha "--admin-password precisa de uma senha"; SENHA_INFORMADA=$2; [ -n "$2" ] || falha "a senha não pode ser vazia"; shift 2;;
    --admin-password=*) SENHA_INFORMADA=${1#*=}; [ -n "$SENHA_INFORMADA" ] || falha "a senha não pode ser vazia"; shift;;
    --timezone) [ $# -ge 2 ] || falha "--timezone precisa de um fuso, por exemplo America/Fortaleza"; FUSO=$2; shift 2;;
    --timezone=*) FUSO=${1#*=}; shift;;
    --desinstalar) REMOVER=1; shift;;
    --apagar-dados) APAGAR=1; shift;;
    -h|--help) sed -n '2,3p' "$0"; exit 0;;
    *) falha "opção desconhecida: $1";;
  esac
done
PORTA_INFORMADA=$PORTA
# Atualização sem --porta mantém a porta já configurada.
if [ -z "$PORTA" ]; then if [ -s "$DADOS/porta" ]; then PORTA=$(cat "$DADOS/porta"); else PORTA=8443; fi; fi
case "$PORTA" in ''|*[!0-9]*) falha "porta inválida: $PORTA";; esac
[ "$PORTA" -ge 1024 ] && [ "$PORTA" -le 65535 ] || falha "use uma porta entre 1024 e 65535"
if [ -n "$SENHA_INFORMADA" ] && [ "${#SENHA_INFORMADA}" -lt 8 ]; then falha "a senha precisa ter pelo menos 8 caracteres"; fi
[ "$(id -u)" = 0 ] || falha "execute como root (sudo sh $0)"

detectar_init(){
  if [ -d /run/systemd/system ] && tem systemctl; then echo systemd
  elif tem rc-service && tem rc-update; then echo openrc
  elif [ -d /run/runit ] || { tem sv && [ -d /etc/sv ]; }; then echo runit
  elif [ -d /etc/init.d ] && { tem update-rc.d || tem chkconfig; }; then echo sysv
  else echo cron
  fi
}
INIT=$(detectar_init)

parar(){
  case "$INIT" in
    systemd) systemctl stop arca 2>/dev/null || true;;
    openrc)  rc-service arca stop 2>/dev/null || true;;
    runit)   sv down arca 2>/dev/null || true;;
    sysv)    [ -x /etc/init.d/arca ] && /etc/init.d/arca stop || true;;
    cron)    [ -x "$BASE/iniciar.sh" ] && "$BASE/iniciar.sh" parar || true;;
  esac
}
desinstalar(){
  parar
  case "$INIT" in
    systemd) systemctl disable arca 2>/dev/null || true; rm -f /etc/systemd/system/arca.service; systemctl daemon-reload || true;;
    openrc)  rc-update del arca default 2>/dev/null || true; rm -f /etc/init.d/arca;;
    runit)   rm -f /var/service/arca /etc/runit/runsvdir/default/arca /run/runit/service/arca; rm -rf /etc/sv/arca;;
    sysv)    if tem update-rc.d; then update-rc.d -f arca remove 2>/dev/null || true; else chkconfig --del arca 2>/dev/null || true; fi; rm -f /etc/init.d/arca;;
    cron)    if tem crontab; then (crontab -l 2>/dev/null | grep -v "$BASE/iniciar.sh" || true) | crontab - || true; fi;;
  esac
  rm -rf "$BASE"; rm -f "$ATUALIZADOR"
  if [ "$APAGAR" = 1 ]; then rm -rf "$DADOS" "$LOGF"; ok "dados apagados"
  else msg "  Dados mantidos em $DADOS (para apagar: --desinstalar --apagar-dados)"; fi
  msg "Servidor Arca removido."
}
[ "$REMOVER" = 1 ] && { desinstalar; exit 0; }

case "$(uname -m)" in
  x86_64|amd64) ARQ=amd64;;
  aarch64|arm64) ARQ=arm64;;
  armv6*|armv7*|armv8l|armhf) ARQ=arm;;
  i386|i486|i586|i686) ARQ=386;;
  ppc64le) ARQ=ppc64le;;
  s390x) ARQ=s390x;;
  riscv64) ARQ=riscv64;;
  *) falha "arquitetura não suportada: $(uname -m)";;
esac
for c in gzip awk; do tem "$c" || falha "o comando $c é necessário"; done
tem curl || tem wget || falha "instale curl ou wget e execute de novo"
tem sha256sum || tem shasum || falha "o comando sha256sum é necessário"
baixar(){ if tem curl; then curl -fL --progress-bar -o "$2" "$1"; else wget -O "$2" "$1"; fi; }
hash_de(){ if tem sha256sum; then sha256sum "$1" | awk '{print $1}'; else shasum -a 256 "$1" | awk '{print $1}'; fi; }
instalar_atualizador(){
  mkdir -p "$(dirname "$ATUALIZADOR")"
  cat > "$ATUALIZADOR" <<FIM
#!/bin/sh
# Baixa o instalador mais recente e aplica; só troca o programa se ele tiver mudado.
set -eu
[ "\$(id -u)" = 0 ] || { echo "ERRO: execute como root" >&2; exit 1; }
BASE=\${ARCA_URL_BASE:-$URL_BASE}
T=\$(mktemp)
trap 'rm -f "\$T"' EXIT
if command -v curl >/dev/null 2>&1; then curl -fsSL -o "\$T" "\$BASE/install.sh"; else wget -q -O "\$T" "\$BASE/install.sh"; fi
sh "\$T" "\$@"
FIM
  chmod 755 "$ATUALIZADOR"
}
eval "ESPERADO=\${SHA_$ARQ:-}"
[ -n "$ESPERADO" ] || falha "programa para $ARQ não disponível"
EXISTIA=0; [ -f "$DADOS/estado.json" ] && EXISTIA=1
MESMO=0; if [ -x "$BIN" ] && [ "$(hash_de "$BIN")" = "$ESPERADO" ]; then MESMO=1; fi
if [ "$MESMO" = 1 ] && [ "$EXISTIA" = 1 ] && [ -z "$SENHA_INFORMADA$FUSO$PORTA_INFORMADA" ]; then
  instalar_atualizador
  msg "Já está na versão mais recente. Nada a atualizar."
  exit 0
fi

msg "Arca Backup: instalando o servidor ($ARQ, inicialização: $INIT)"
TMP=$(mktemp -d 2>/dev/null || { d=/tmp/arca-$$; mkdir -m 700 "$d"; echo "$d"; })
trap 'rm -rf "$TMP"' EXIT
if [ "$MESMO" = 1 ]; then
  cp "$BIN" "$TMP/arca-servidor-$ARQ"
  ok "programa já atualizado, sem download"
else
  msg "  Baixando o programa..."
  baixar "$URL_BASE/binarios/arca-servidor-$ARQ.gz" "$TMP/p.gz" || falha "não foi possível baixar o programa"
  gzip -dc "$TMP/p.gz" > "$TMP/arca-servidor-$ARQ" || falha "arquivo baixado corrompido"
  [ "$(hash_de "$TMP/arca-servidor-$ARQ")" = "$ESPERADO" ] || falha "o SHA256 do programa baixado não confere; nada foi alterado"
  ok "programa baixado e SHA256 conferido"
fi
chmod 755 "$TMP/arca-servidor-$ARQ"
"$TMP/arca-servidor-$ARQ" versao >/dev/null 2>&1 || falha "o programa não executa neste sistema (se /tmp tiver noexec, defina TMPDIR)"
ok "programa compatível com este sistema"
if [ -n "$FUSO" ]; then "$TMP/arca-servidor-$ARQ" testar-fuso "$FUSO" || falha "fuso horário inválido: $FUSO (exemplo: America/Fortaleza)"; fi

parar
mkdir -p "$BASE" "$DADOS"
cp "$TMP/arca-servidor-$ARQ" "$BIN.novo"; chmod 755 "$BIN.novo"; mv -f "$BIN.novo" "$BIN"

# Conta própria, sem login. Sem ferramenta para criar contas, roda como root e avisa.
if ! id "$CONTA" >/dev/null 2>&1; then
  if tem useradd; then useradd -r -M -d "$DADOS" -s /bin/false "$CONTA" 2>/dev/null || useradd -M -d "$DADOS" -s /bin/false "$CONTA" || true
  elif tem adduser; then adduser -S -D -H -h "$DADOS" -s /bin/false "$CONTA" 2>/dev/null || adduser --system --no-create-home --home "$DADOS" "$CONTA" || true
  fi
fi
if id "$CONTA" >/dev/null 2>&1; then ok "conta de serviço $CONTA"; else CONTA=root; msg "  Aviso: não foi possível criar a conta de serviço; o servidor rodará como root"; fi

SENHA=""
if [ -n "$SENHA_INFORMADA" ]; then
  printf '%s\n' "$SENHA_INFORMADA" | "$BIN" definir-senha-admin --dados "$DADOS"
  ok "senha do admin definida"
elif [ ! -f "$DADOS/estado.json" ]; then
  SENHA=$(LC_ALL=C tr -dc 'A-Za-z0-9' </dev/urandom | dd bs=1 count=20 2>/dev/null)
  printf '%s\n' "$SENHA" | "$BIN" definir-senha-admin --dados "$DADOS"
  ok "usuário admin criado"
else
  ok "dados existentes mantidos"
fi
if [ -n "$FUSO" ]; then printf '%s\n' "$FUSO" > "$DADOS/fuso"; ok "fuso horário: $FUSO"; fi
printf '%s\n' "$PORTA" > "$DADOS/porta"
chown -R "$CONTA" "$DADOS"; chmod 700 "$DADOS"
touch "$LOGF"; chown "$CONTA" "$LOGF"; chmod 640 "$LOGF"
tem restorecon && restorecon -R "$BASE" "$DADOS" "$LOGF" 2>/dev/null || true # SELinux (Red Hat, Fedora, Rocky, Alma)
CMD="$BIN servir --dados $DADOS --porta $PORTA"

scripts_iniciar(){ # usado por SysV e pelo modo cron
cat > "$1" <<FIM
#!/bin/sh
### BEGIN INIT INFO
# Provides:          arca
# Required-Start:    \$network \$remote_fs
# Required-Stop:     \$network \$remote_fs
# Default-Start:     2 3 4 5
# Default-Stop:      0 1 6
# Short-Description: Arca Backup
### END INIT INFO
# chkconfig: 2345 90 10
# description: Arca Backup
PID=$DADOS/arca.pid
ativo(){ [ -f "\$PID" ] && kill -0 "\$(cat "\$PID")" 2>/dev/null; }
case "\${1:-start}" in
  start|iniciar) ativo && exit 0
    if [ "$CONTA" = root ]; then sh -c 'nohup $CMD >>$LOGF 2>&1 & echo \$! > '"\$PID"
    else su -s /bin/sh $CONTA -c 'nohup $CMD >>$LOGF 2>&1 & echo \$! > '"\$PID"; fi;;
  stop|parar) if ativo; then kill "\$(cat "\$PID")"; n=0; while ativo && [ \$n -lt 7 ]; do sleep 1; n=\$((n+1)); done; fi; rm -f "\$PID";;
  restart) "\$0" stop; sleep 1; "\$0" start;;
  status) ativo && echo ativo || { echo parado; exit 3; };;
esac
FIM
chmod 755 "$1"
}
case "$INIT" in
  systemd)
    { cat <<FIM
[Unit]
Description=Arca Backup
After=network-online.target
Wants=network-online.target

[Service]
ExecStart=$CMD
User=$CONTA
Restart=always
RestartSec=5
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ProtectHome=true
ReadWritePaths=$DADOS

[Install]
WantedBy=multi-user.target
FIM
    } > /etc/systemd/system/arca.service
    systemctl daemon-reload; systemctl enable arca >/dev/null 2>&1; systemctl restart arca;;
  openrc)
    { cat <<FIM
#!/sbin/openrc-run
description="Arca Backup"
command="$BIN"
command_args="servir --dados $DADOS --porta $PORTA"
command_user="$CONTA"
command_background=true
pidfile="/run/arca.pid"
output_log="$LOGF"
error_log="$LOGF"
depend() { need net; }
FIM
    } > /etc/init.d/arca
    chmod 755 /etc/init.d/arca; rc-update add arca default >/dev/null 2>&1; rc-service arca restart >/dev/null 2>&1 || rc-service arca start;;
  runit)
    mkdir -p /etc/sv/arca
    { echo '#!/bin/sh'; echo 'exec 2>&1'; if tem chpst; then echo "exec chpst -u $CONTA $CMD >>$LOGF"; else echo "exec su -s /bin/sh $CONTA -c 'exec $CMD >>$LOGF'"; fi; } > /etc/sv/arca/run
    chmod 755 /etc/sv/arca/run
    for d in /var/service /etc/runit/runsvdir/default /run/runit/service; do [ -d "$d" ] && { ln -sf /etc/sv/arca "$d/arca"; break; }; done
    sleep 6; sv up arca 2>/dev/null || true;;
  sysv)
    scripts_iniciar /etc/init.d/arca
    if tem update-rc.d; then update-rc.d arca defaults >/dev/null 2>&1 || true; else chkconfig --add arca || true; fi
    /etc/init.d/arca start;;
  cron)
    scripts_iniciar "$BASE/iniciar.sh"
    if tem crontab; then (crontab -l 2>/dev/null | grep -v "$BASE/iniciar.sh" || true; echo "@reboot $BASE/iniciar.sh iniciar") | crontab -
    else msg "  Aviso: sem systemd, OpenRC, runit, SysV ou cron. Configure a inicialização de: $BASE/iniciar.sh iniciar"; fi
    "$BASE/iniciar.sh" iniciar;;
esac
ok "serviço configurado"

if tem ufw && ufw status 2>/dev/null | grep -q 'Status: active'; then ufw allow "$PORTA/tcp" >/dev/null && ok "porta $PORTA liberada no ufw"
elif tem firewall-cmd && firewall-cmd --state >/dev/null 2>&1; then firewall-cmd --permanent --add-port="$PORTA/tcp" >/dev/null && firewall-cmd --reload >/dev/null && ok "porta $PORTA liberada no firewalld"
fi

SUBIU=0; i=0
while [ $i -lt 15 ]; do
  if tem curl; then curl -ksf -o /dev/null "https://127.0.0.1:$PORTA/" && { SUBIU=1; break; }
  elif tem wget; then wget -q --no-check-certificate -O /dev/null "https://127.0.0.1:$PORTA/" && { SUBIU=1; break; }
  else sleep 3; SUBIU=2; break; fi
  sleep 1; i=$((i+1))
done
[ "$SUBIU" = 0 ] && falha "o servidor não respondeu na porta $PORTA. Veja $LOGF ou o registro do serviço."

instalar_atualizador
IP=""
if tem hostname; then IP=$(hostname -I 2>/dev/null | awk '{print $1}') || true; fi
if [ -z "$IP" ] && tem ip; then IP=$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<NF;i++)if($i=="src")print $(i+1)}') || true; fi
msg ""
if [ "$EXISTIA" = 1 ] && [ -z "$SENHA_INFORMADA" ]; then
  msg "ATUALIZAÇÃO CONCLUÍDA"
  msg "  Endereço: https://${IP:-IP-DESTE-SERVIDOR}:$PORTA"
  exit 0
fi
msg "INSTALAÇÃO CONCLUÍDA"
msg "  Endereço: https://${IP:-IP-DESTE-SERVIDOR}:$PORTA"
msg "  O navegador avisará sobre o certificado próprio do servidor na primeira visita."
if [ -n "$SENHA_INFORMADA" ]; then
  msg "  Usuário:  admin"
  msg "  Senha:    Redefina após primeiro login"
elif [ -n "$SENHA" ]; then
  msg "  Usuário:  admin"
  msg "  Senha:    $SENHA"
  msg "  Guarde esta senha agora: ela não será mostrada de novo."
fi
exit 0
