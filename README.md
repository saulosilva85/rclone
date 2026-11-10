# Arca Backup (nome provisório)

Painel web para acompanhar e operar o backup de computadores Windows e servidores Linux para o Oracle Cloud Object Storage.

- **Servidor (Linux):** hospeda o painel. O cliente instala em um servidor próprio.
- **Agente (Windows e Linux):** instalado em cada computador que terá backup. Usa o rclone oficial, com o SHA256 conferido.

## Requisitos do servidor

- Linux 3.2 ou mais novo: Debian, Ubuntu, Red Hat, Rocky, Alma, Fedora, Alpine e outras
- Processador amd64, arm64, arm (v6+), 386, ppc64le, s390x ou riscv64
- Acesso de `root`, `curl` ou `wget`, `gzip`, `sha256sum` e internet durante a instalação

## Instalação

```
wget --show-progress -O install.sh https://raw.githubusercontent.com/saulosilva85/rclone/atualizacoes/install.sh
sudo sh install.sh --admin-password 'SUA_SENHA' --timezone America/Fortaleza
```

| Opção | Função |
|---|---|
| `--admin-password 'SENHA'` | Define a senha do `admin` (mínimo de 8 caracteres). Sem ela, o instalador gera uma senha e a mostra uma única vez. |
| `--timezone America/Fortaleza` | Define o fuso horário do servidor. |
| `--porta 8443` | Define a porta HTTPS (padrão 8443, entre 1024 e 65535). |
| `--desinstalar` | Remove o programa e mantém os dados. |
| `--desinstalar --apagar-dados` | Remove o programa e os dados. |

A porta é liberada automaticamente no `ufw` e no `firewalld`. Em nuvem, libere também a porta na regra de rede do provedor.

## Acesso

Abra `https://IP-DO-SERVIDOR:8443` e entre com o usuário `admin`.

O navegador avisa sobre o certificado próprio do servidor na primeira visita. Troque a senha no primeiro acesso, em **Usuários > Alterar senha**.

## Atualização

```
sudo arca-atualizar
```

Só baixa algo se o programa tiver mudado. Mantém dados, senha, fuso e porta. Depois, recarregue a página com `Ctrl+F5`.

## Serviço (systemd)

| Ação | Comando |
|---|---|
| Status | `systemctl status arca` |
| Parar | `systemctl stop arca` |
| Iniciar | `systemctl start arca` |
| Reiniciar | `systemctl restart arca` |
| Registros | `journalctl -u arca -n 50` |

O serviço inicia junto com o sistema operacional.

## Instalação nos computadores Windows

1. No painel, preencha **Preferências > Armazenamento** (bucket, região e endpoint).
2. Em **Instalar em um computador**, baixe o instalador. Cada arquivo vale para um computador, por 7 dias.
3. No computador, clique com o botão direito e escolha **Executar como administrador**.

O computador precisa alcançar o servidor na porta do painel. A instalação fica em `C:\Backup-OCI` e cria as tarefas agendadas `Backup OCI` (diária) e `Arca Agente` (a cada 5 minutos).

Se o antivírus bloquear o `rclone.exe`, libere-o como aplicativo confiável. O caminho e o SHA256 estão em **Integridade do rclone**, no painel.

Para remover de um computador (prompt de administrador):

```
schtasks /delete /tn "Backup OCI" /f
schtasks /delete /tn "Arca Agente" /f
rmdir /s /q C:\Backup-OCI
```

## Instalação nos servidores Linux (backup)

1. No painel, em **Instalar em um computador**, clique em **Baixar para Linux**. Cada arquivo vale para um servidor, por 7 dias.
2. Copie o arquivo para o servidor e execute como `root`:

```
sudo sh arca-instalador-linux.sh
```

O instalador pergunta o nome, as pastas, o horário e a chave de acesso. Também aceita tudo por opção:

```
sudo sh arca-instalador-linux.sh --nome srv-web --pastas "/etc,/home,/var/www" --horario 22:00 --access-key CHAVE --secret-key SEGREDO
```

- Requisitos: `curl` (ou `wget` com suporte a `--ca-certificate`), `unzip` (ou `bsdtar`/`python3`) e `sha256sum`.
- Processadores: amd64, arm64, arm v7 e 386.
- O rclone vem do site oficial (downloads.rclone.org; se não responder, a página oficial de versões no GitHub) e só é usado se o SHA256 conferir.
- Instala em `/opt/arca-agente`; chave e configuração em `/etc/arca-agente`, acessíveis só pelo `root`; registros em `/var/log/arca-agente`.
- Agenda com systemd (`arca-backup.timer` e `arca-agente.timer`) ou, sem systemd, com cron.
- Links simbólicos são guardados como links. Arquivos abertos são copiados como estão: para bancos de dados, gere uma exportação antes, colocando um script executável em `/etc/arca-agente/antes-do-backup.sh`.
- Para trocar o nome do servidor no painel, baixe um instalador novo.

Comandos no servidor:

| Ação | Comando |
|---|---|
| Rodar um backup agora | `sudo /opt/arca-agente/arca-agente.sh backup` |
| Ver os agendamentos (systemd) | `systemctl list-timers 'arca-*'` |
| Remover | `sudo /opt/arca-agente/arca-agente.sh desinstalar` |

## Recuperar a senha do admin pelo terminal

```
sudo systemctl stop arca
sudo /opt/arca/arca-servidor definir-senha-admin --dados /var/lib/arca
sudo chown -R arca /var/lib/arca
sudo systemctl start arca
```

No segundo comando, digite a nova senha e pressione Enter. Ela aparece na tela durante a digitação.

## Onde ficam os arquivos no servidor

| Caminho | Conteúdo |
|---|---|
| `/opt/arca` | Programa |
| `/var/lib/arca` | Dados, certificado, fuso e porta |
| `/usr/local/bin/arca-atualizar` | Comando de atualização |


## Arquivos deste repositório

| Arquivo | Conteúdo |
|---|---|
| `install.sh` | Instalador do servidor |
| `binarios/` | Programa do servidor, um arquivo por processador |
| `backup.cmd` | Script original de backup que deu origem ao agente Windows |

A branch `atualizacoes` é usada pelo instalador e pelo `arca-atualizar`, e não deve ser apagada.
