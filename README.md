# Arca Backup (nome provisório)

Painel web para acompanhar e operar o backup de computadores Windows para o Oracle Cloud Object Storage.

- **Servidor (Linux):** hospeda o painel. O cliente instala em um servidor próprio.
- **Agente (Windows):** instalado em cada computador que terá backup. Usa o rclone oficial, com o SHA256 conferido.

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
