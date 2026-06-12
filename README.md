# Restic Backup Automatizado para Windows

Projeto de backup automatizado com Restic para Windows

## Resumo Executivo

- entrada publica e enxuta na raiz: install.bat, backup.bat, check.bat, sincronizar_externo.bat, ativar_agora.bat, centro_de_controle.bat e configurar.bat (compatibilidade)
- exportacao limpa para distribuicao via preparar_distribuicao.bat
- logica de aplicacao isolada em app/
- provisionamento e cadastro de tarefas isolados em setup/
- estado local separado em runtime/
- utilitarios auxiliares isolados em tools/
- configuracao operacional resolvida por variaveis de ambiente do Windows
- logs, segredos e binarios baixados fora do codigo de aplicacao
- espelhamento externo opcional para copiar snapshots ativos para outro repositorio, como um HD externo

## Estrutura do Repositorio

```text
C:\restic
|-- app/
|   |-- backup.ps1
|   |-- check.ps1
|   |-- config.ps1
|   \-- telegram.ps1
|-- setup/
|   |-- control_center.ps1
|   |-- install.ps1
|   |-- register_tasks.ps1
|   |-- setup_env.ps1
|   |-- env_helper.ps1
|   \-- show_env.ps1
|-- tools/
|   |-- dir_sizes.ps1
|   |-- export_active_snapshots.ps1
|   |-- restore_snapshot.ps1
|   \-- find_large_dirs.ps1
|-- runtime/
|   |-- bin/
|   |-- logs/
|   \-- secrets/
|-- backup.bat
|-- check.bat
|-- sincronizar_externo.bat
|-- install.bat
|-- ativar_agora.bat
|-- centro_de_controle.bat
|-- configurar.bat
|-- preparar_distribuicao.bat
|-- .gitignore
\-- README.md
```

### Papel de cada area

- app/: fluxo principal de backup, check, parser de notificacao e resolucao de configuracao.
- setup/: instalacao assistida, persistencia de variaveis e cadastro de tarefas.
- tools/: scripts opcionais de diagnostico e apoio. Nao fazem parte do fluxo padrao de backup.
- runtime/bin/: binarios locais baixados pelo instalador, como restic.exe quando nao instalado por winget.
- runtime/logs/: logs operacionais e logs de launcher.
- runtime/secrets/: arquivo local de senha do repositorio.

## Modelo de Seguranca

Este projeto segue estes principios:

- a configuracao vem de variaveis RESTIC_* no Windows, resolvidas em Process -> User -> Machine
- o arquivo de senha do Restic fica fora do codigo, em runtime/secrets/ ou em outro caminho definido pelo operador
- logs e segredos ficam em runtime/, separados da logica da aplicacao
- .gitignore protege runtime/logs/, runtime/secrets/ e runtime/bin/ para evitar commit acidental de estado local

### O que nao deve ser distribuido preenchido

- runtime/secrets/restic-password.txt com senha real
- runtime/logs com historico operacional
- runtime/bin/restic.exe se a estrategia da equipe for instalar o Restic via winget ou outro gerenciador central

## Fluxo Recomendado de Implantacao

### Opcao 1: instalacao assistida

Essa e a opcao recomendada para distribuicao.

Por duplo clique:

```text
install.bat
```

Ou por PowerShell:

```powershell
$ProjectRoot = 'C:\restic'
Set-Location $ProjectRoot
.\setup\install.ps1
```

O instalador consegue:

- copiar a estrutura organizada para outra pasta
- localizar ou instalar o restic.exe
- baixar o binario oficial para runtime/bin/
- criar o arquivo de senha do repositorio
- inicializar o repositorio Restic
- validar restic.exe
- validar Telegram com getMe e getChat
- validar acesso ao repositorio com restic snapshots
- alertar sobre unidade mapeada versus UNC
- persistir variaveis RESTIC_*
- cadastrar tarefas no Task Scheduler
- opcionalmente rodar um backup de validacao ao final

### Opcao 2: provisionamento manual controlado

Use esta opcao quando a equipe quiser controlar cada etapa explicitamente.

## Pre-Requisitos

- Windows com PowerShell 5.1 ou superior
- Restic instalado ou acesso para baixa-lo
- permissao para gravar variaveis de ambiente no escopo desejado
- permissao para criar tarefas no Task Scheduler, se for automatizar agendamento
- repositorio local, externo ou UNC acessivel pela conta que executara o backup
- Telegram opcional, caso a operacao precise de notificacao

## Passo 1 - Instalar ou localizar o Restic

Exemplo com winget:

```powershell
winget install --exact --id restic.restic --scope Machine
```

Validacao:

```powershell
$ResticExe = (Get-Command restic).Source
restic version
```

Se preferir baixar o binario manualmente, o instalador tambem consegue colocar o executavel em runtime/bin/.

## Passo 2 - Definir caminhos operacionais

Exemplo padrao:

```powershell
$ProjectRoot = 'C:\restic'
$RepositoryPath = 'E:\restic-backup'
$PasswordFilePath = Join-Path $ProjectRoot 'runtime\secrets\restic-password.txt'
$LogDir = Join-Path $ProjectRoot 'runtime\logs'
```

Recomendacoes:

- prefira um disco fisico diferente da origem do backup
- para tarefas agendadas com outra conta, evite depender de unidade mapeada
- quando o repositorio estiver em rede, prefira caminho UNC

## Passo 3 - Criar e proteger o arquivo de senha

```powershell
$ProjectRoot = 'C:\restic'
$PasswordFilePath = Join-Path $ProjectRoot 'runtime\secrets\restic-password.txt'

New-Item -ItemType Directory -Path (Split-Path -Parent $PasswordFilePath) -Force | Out-Null
Set-Content -Path $PasswordFilePath -Value '<SUA_SENHA_FORTE>' -NoNewline -Encoding ASCII

icacls $PasswordFilePath /inheritance:r
icacls $PasswordFilePath /grant:r "$env:USERNAME:(R)" "Administrators:(F)" "SYSTEM:(F)"
```

Se a tarefa rodar com outra conta, conceda leitura explicitamente para essa conta.

## Passo 4 - Inicializar o repositorio Restic

```powershell
$ResticExe = (Get-Command restic).Source
$RepositoryPath = 'E:\restic-backup'
$PasswordFilePath = 'C:\restic\runtime\secrets\restic-password.txt'

& $ResticExe init --repo $RepositoryPath --password-file $PasswordFilePath
& $ResticExe snapshots --repo $RepositoryPath --password-file $PasswordFilePath
```

Se o repositorio ja existir, nao rode init novamente.

## Passo 5 - Configurar Telegram

### Criar o bot

1. Abra conversa com o BotFather.
2. Rode /newbot.
3. Defina nome e username do bot.
4. Guarde o token em local seguro.

Exemplo de formato do token:

```text
123456789:AAExemploTokenMuitoSecretoAqui
```

### Validar o token

```powershell
$Token = '<SEU_TOKEN>'
Invoke-RestMethod -Uri "https://api.telegram.org/bot$Token/getMe"
```

### Descobrir o Chat ID

```powershell
$Token = '<SEU_TOKEN>'
Invoke-RestMethod -Uri "https://api.telegram.org/bot$Token/deleteWebhook?drop_pending_updates=false"
$Response = Invoke-RestMethod -Uri "https://api.telegram.org/bot$Token/getUpdates"
$Response.result | ConvertTo-Json -Depth 100
```

Procure message.chat.id no retorno. Para grupo, adicione o bot ao grupo, envie mensagem e repita o getUpdates.

## Passo 6 - Persistir a configuracao do projeto

```powershell
$ProjectRoot = 'C:\restic'
$ResticExe = (Get-Command restic).Source
$RepositoryPath = 'E:\restic-backup'
$PasswordFilePath = Join-Path $ProjectRoot 'runtime\secrets\restic-password.txt'
$LogDir = Join-Path $ProjectRoot 'runtime\logs'

Set-Location $ProjectRoot

$SetupArgs = @{
  Scope          = 'User'
  ResticExe      = $ResticExe
  Repository     = $RepositoryPath
  SecretFilePath = $PasswordFilePath
  LogDir         = $LogDir
  LogKeepDays    = 30
  TelegramToken  = '<SEU_TOKEN>'
  TelegramChatId = '<SEU_CHAT_ID>'
  KeepLast       = 7
  KeepWeekly     = 4
  KeepMonthly    = 3
  BackupSources  = @('C:\Users')
  BackupExcludes = @(
    'AppData\Local\Temp'
    'AppData\Local\Packages'
    'AppData\Local\Microsoft\Windows\INetCache'
    'AppData\Local\Google\Chrome\User Data\Default\Cache'
    'AppData\Local\Microsoft\Edge\User Data\Default\Cache'
    'OneDrive\Temp'
    '*.tmp'
    '.codex'
    '.cache'
    'AppData\Local\Microsoft\WindowsApps'
    'CodexSandboxOffline'
  )
}

.\setup\setup_env.ps1 @SetupArgs
```

### Escopo da configuracao

- User: grava em HKCU:\Environment
- Machine: grava em HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Environment

Use Machine quando a tarefa rodar fora do contexto do usuario atual ou quando a configuracao precisar ser global para a maquina.

### Teste sem gravar nada

```powershell
.\setup\setup_env.ps1 -WhatIf -ResticExe $ResticExe -Repository $RepositoryPath -SecretFilePath $PasswordFilePath
```

## Passo 7 - Conferir a configuracao efetiva

```powershell
$ProjectRoot = 'C:\restic'
Set-Location $ProjectRoot
.\setup\show_env.ps1
```

O comando mostra:

- nome da variavel
- escopo de origem
- valor efetivo
- token do Telegram mascarado

Edicao dinamica da configuracao (ajudante):

```powershell
$ProjectRoot = 'C:\restic'
Set-Location $ProjectRoot
.\setup\env_helper.ps1 -Scope User
```

Esse ajudante abre um fluxo interativo para atualizar variaveis RESTIC_* sem hardcode em script.
Tambem funciona por parametros para automacao, por exemplo:

```powershell
.\setup\env_helper.ps1 -Scope User -TelegramChatId '123456789' -KeepLast 10
```

Centro de Controle por menu (duplo clique):

```text
centro_de_controle.bat
```

Compatibilidade:

- configurar.bat continua existindo como alias legado e abre o mesmo Centro de Controle

No Centro de Controle, voce consegue:

- seguir um menu principal organizado por visualizacao, configuracao e operacoes
- ver um painel resumido e mais legivel da configuracao atual
- ajustar horario do backup e criar/editar o check semanal do scheduler
- ajustar retencao e quantidade de snapshots guardados
- visualizar os snapshots que a politica atual manteria, em ordem: recentes, semanais extras e mensais extras
- ajustar fontes e exclusoes do backup
- ajustar Telegram, caminhos principais e espelho externo
- salvar/aplicar/remover perfis (casa/trabalho/outros)
- testar envio Telegram
- rodar backup imediato
- iniciar restore guiado por snapshot
- transferir para DISCO EXTERNO com tres opcoes claras: carga inicial completa, atualizacao semanal e desempacotamento no proprio disco
- abrir a visao tecnica completa ou o assistente avancado quando precisar

Observacao sobre agendamento e permissao:

- para tarefas CurrentUser comuns, o projeto nao precisa rodar sempre como administrador
- elevacao so passa a ser necessaria quando a tarefa for criada/alterada com RunLevel Highest ou em SYSTEM
- se voce herdou uma tarefa antiga criada como admin, abra o Centro de Controle elevado apenas para migrar/editar esse agendamento

## Exportar pacote limpo para distribuicao

Para gerar uma copia pronta para enviar sem levar runtime, logs e segredos locais:

```text
preparar_distribuicao.bat
```

Ou por PowerShell:

```powershell
$ProjectRoot = 'C:\restic'
Set-Location $ProjectRoot
.\setup\prepare_distribution.ps1 -OutputDir (Join-Path $ProjectRoot 'dist\restic-package') -Force
```

Esse fluxo exporta apenas os arquivos publicos do projeto, recria runtime/ vazio com .gitkeep e evita carregar restic-password.txt, logs e outros residuos locais para o pacote final.

Nas telas de edicao do Centro de Controle:

- Enter mantem o valor atual
- digite voltar para cancelar a tela atual e retornar ao menu
- em campos como Telegram/exclusoes, digite - para limpar o valor
- nas telas principais, o fluxo agora mostra contexto, coleta os valores, resume o que sera aplicado e so depois pede escopo ou confirmacao
- no agendamento, os dias da semana podem ser digitados em portugues: domingo, segunda, terca, quarta, quinta, sexta ou sabado

## Passo 8 - Executar validacao manual

Backup manual:

```powershell
$ProjectRoot = 'C:\restic'
Set-Location $ProjectRoot
.\backup.bat
```

Backup manual por duplo clique:

```text
ativar_agora.bat
```

Use ativar_agora.bat quando quiser disparar um backup imediato sem abrir terminal.
Esse launcher chama backup.bat internamente e mantem a janela aberta ao final para revisao humana.
O scheduler continua apontando para backup.bat.

Check parcial:

```powershell
$ProjectRoot = 'C:\restic'
Set-Location $ProjectRoot
.\check.bat
```

Check completo:

```powershell
$ProjectRoot = 'C:\restic'
Set-Location $ProjectRoot
.\app\check.ps1 -FullCheck
```

Restore (desempacotar snapshot) usando senha/configuracao atual:

```powershell
$ProjectRoot = 'C:\restic'
Set-Location $ProjectRoot
.\tools\restore_snapshot.ps1 -SnapshotId '<SNAPSHOT_ID>' -TargetPath 'D:\restore-temp'
```

No restore_snapshot.ps1, o caminho da senha vem automaticamente de RESTIC_PASSWORD_FILE via app/config.ps1.

Empacotar snapshots ativos para levar em HD externo ou outro repositorio:

```powershell
$ProjectRoot = 'C:\restic'
Set-Location $ProjectRoot
.\tools\export_active_snapshots.ps1 -DestinationRepository 'F:\restic-export'
```

Com password file diferente no destino:

```powershell
$ProjectRoot = 'C:\restic'
Set-Location $ProjectRoot
.\tools\export_active_snapshots.ps1 -DestinationRepository 'F:\restic-export' -DestinationPasswordFile 'F:\restic-export-password.txt'
```

Esse fluxo usa restic copy para transferir todos os snapshots atualmente ativos para outro repositorio. Se o destino ainda nao existir, o script inicializa o novo repositorio com os mesmos parametros de chunk da origem para preservar deduplicacao.

Execucoes futuras no mesmo destino sao incrementais: snapshots ja copiados sao ignorados pelo proprio Restic.

Se preferir um launcher publico na raiz do projeto, use:

```text
sincronizar_externo.bat
```

Esse launcher usa RESTIC_EXPORT_REPOSITORY e RESTIC_EXPORT_PASSWORD_FILE quando voce nao passa argumentos manualmente.

Para o seu caso de uso, o desenho fica assim:

- primeira execucao: o destino externo recebe todos os snapshots ativos
- fim de semana seguinte: a mesma sincronizacao copia apenas os snapshots ainda ausentes no destino
- ou seja, nao e um zip completo toda semana; e um segundo repositorio Restic que vai sendo atualizado por diferenca de snapshots

Observacao importante: o script nao copia automaticamente o arquivo de senha para o HD externo. Leve a senha por um canal separado e seguro.

Fluxo recomendado pelo menu para DISCO EXTERNO:

- [11] Transferencia para DISCO EXTERNO
- [1] Transferencia completa (inicial)
- [2] Atualizacao semanal
- [3] Desempacotar tudo no disco externo

Na transferencia inicial, o sistema:

- detecta os discos USB com letra de unidade
- pede para qual disco voce quer transferir
- pede a pasta base no disco externo, usando restic_backup como padrao
- cria a estrutura padrao X:\restic_backup\repo, X:\restic_backup\kit e X:\restic_backup\restore-staging, ou a mesma estrutura dentro da pasta que voce escolher
- atualiza o kit limpo de recuperacao no proprio disco externo
- copia todos os snapshots ativos para o repositorio externo

Na atualizacao semanal, o sistema:

- detecta novamente os discos USB conectados
- pede qual disco voce quer atualizar
- pede a pasta base usada naquele disco
- exige que esse disco ja tenha recebido a transferencia inicial
- sincroniza apenas os snapshots ainda ausentes no repositorio externo

No desempacotamento completo no disco externo, o sistema:

- detecta novamente os discos USB conectados
- pede o disco e a pasta base onde o repositório externo foi criado
- usa latest por padrao, ou outro snapshot se voce informar
- permite escolher entre modo rapido e modo verificado
- no modo rapido, restaura sem a verificacao final de conteudo e tende a terminar antes
- no modo verificado, confere o conteudo restaurado ao final e pode demorar bem mais
- se a pasta de destino ja tiver arquivos, alerta antes e permite limpar essa pasta ou escolher outro nome
- se o restore for interrompido, o conteudo parcial fica preservado e o staging recebe um arquivo _restore_status.txt com o estado da tentativa
- na proxima tentativa, o menu le esse arquivo de status e mostra se a ultima execucao terminou, falhou ou ficou interrompida antes de voce decidir limpar ou reaproveitar a pasta
- restaura tudo para uma subpasta datada dentro de restore-staging, no proprio disco externo

Em outras palavras: a opcao semanal nao recria tudo do zero. Ela reaproveita o repositorio Restic do disco externo e completa apenas o que falta.

## Passo 9 - Cadastrar tarefas no Task Scheduler

O caminho recomendado e usar o script de cadastro automatico ou o instalador.

Exemplo direto:

```powershell
$ProjectRoot = 'C:\restic'
Set-Location $ProjectRoot

$TaskArgs = @{
  InstallDir        = $ProjectRoot
  BackupTime        = '02:00'
  CreateCheckTask   = $true
  CheckMode         = 'partial'
  CheckDay          = 'Sunday'
  CheckTime         = '03:30'
  CreateExportTask  = $true
  ExportDay         = 'Sunday'
  ExportTime        = '05:00'
  RunAs             = 'CurrentUser'
  HighestPrivileges = $false
}

.\setup\register_tasks.ps1 @TaskArgs
```

As tarefas registradas apontam para:

- backup.bat na raiz do projeto
- check.bat na raiz do projeto
- sincronizar_externo.bat na raiz do projeto, quando o espelho externo semanal for solicitado

### Observacoes importantes sobre o scheduler

- se RunAs = System, prefira Scope Machine
- para CurrentUser, use HighestPrivileges = $false por padrao e so eleve quando houver necessidade real
- se o repositorio estiver em rede, prefira UNC a unidade mapeada
- se a conta da tarefa for diferente da conta atual, confira ACL do arquivo de senha e acesso ao repositorio

## Variaveis de Ambiente Suportadas

| Variavel | Obrigatoria | Funcao |
| --- | --- | --- |
| RESTIC_EXE | Sim | Caminho completo do restic.exe |
| RESTIC_REPOSITORY | Sim | Caminho do repositorio |
| RESTIC_PASSWORD_FILE | Sim | Caminho do arquivo de senha |
| RESTIC_LOG_DIR | Nao | Diretorio de logs |
| RESTIC_LOG_KEEP_DAYS | Nao | Retencao de logs |
| RESTIC_EXPORT_REPOSITORY | Nao | Repositorio externo para espelhamento manual e semanal |
| RESTIC_EXPORT_PASSWORD_FILE | Nao | Arquivo de senha do repositorio externo; se vazio, usa RESTIC_PASSWORD_FILE |
| RESTIC_TELEGRAM_TOKEN | Nao | Token do bot |
| RESTIC_TELEGRAM_CHATID | Nao | Chat de notificacao |
| RESTIC_KEEP_LAST | Nao | Guarda os N snapshots mais recentes |
| RESTIC_KEEP_WEEKLY | Nao | Alem do keep-last, guarda 1 snapshot representativo por semana nas ultimas N semanas |
| RESTIC_KEEP_MONTHLY | Nao | Alem do keep-last, guarda 1 snapshot representativo por mes nos ultimos N meses |
| RESTIC_BACKUP_SOURCES | Nao | Fontes, separadas por ; |
| RESTIC_BACKUP_EXCLUDES | Nao | Exclusoes, separadas por ; |

Observacao: as variaveis RESTIC_* sao controladas no Registro do Windows (Scope User ou Machine), nao em arquivo .env.

### Como funciona a retencao de snapshots

O projeto executa o Restic assim:

```text
restic forget --prune --keep-last <N> --keep-weekly <N> --keep-monthly <N>
```

Importante: essas regras nao sao somadas como um numero fixo. O Restic avalia todas elas e mantem um snapshot se ele bater em qualquer regra.

Na pratica:

- keep-last 7 = guarda os 7 snapshots mais recentes
- keep-weekly 4 = alem disso, guarda 1 snapshot representativo por semana nas ultimas 4 semanas
- keep-monthly 3 = alem disso, guarda 1 snapshot representativo por mes nos ultimos 3 meses

Por isso, o total final nao e sempre 7, 8, 10 ou 14. Ele depende de sobreposicao entre as regras e do calendario.

Exemplo:

- keep-last 7, keep-weekly 4, keep-monthly 3 nao significa guardar exatamente 14 snapshots
- em alguns cenarios pode guardar so um pouco mais que 7
- em outros pode guardar varios snapshots antigos adicionais, porque eles representam semanas ou meses que nao estao mais cobertos pelos 7 ultimos

Se o objetivo for simplesmente sempre manter so os ultimos N snapshots, configure assim:

```text
RESTIC_KEEP_LAST = N
RESTIC_KEEP_WEEKLY = 0
RESTIC_KEEP_MONTHLY = 0
```

Ou seja: weekly e monthly servem para preservar pontos de restauracao mais antigos e mais espalhados no tempo, nao para contar os snapshots mais recentes.

Para inspecionar isso de forma organizada sem alterar nada no repositorio:

```powershell
.\tools\show_retention_layout.ps1
```

Esse comando roda um dry-run da politica atual e organiza a leitura em tres camadas:

- recentes = snapshots dentro da janela keep-last
- semanais extras = snapshots antigos que continuam protegidos pela regra semanal
- mensais extras = snapshots antigos que continuam protegidos pela regra mensal

O mesmo fluxo tambem ficou disponivel no Centro de Controle, no grupo de visualizacao e diagnostico.

## Operacao Diaria

### Arquivos de log

Por padrao, os logs ficam em:

```text
C:\restic\runtime\logs
```

Arquivos tipicos:

- backup_YYYY-MM-DD_HH-mm-ss.log
- check_YYYY-MM-DD_HH-mm-ss.log
- telegram-delivery.log
- backup-launcher.log
- check-launcher.log
- external-sync-launcher.log
- install-launcher.log

O arquivo telegram-delivery.log registra cada tentativa de envio de notificacao, incluindo sucesso, falha, exit code e as primeiras linhas retornadas por telegram.ps1 quando houver erro.

### Como identificar o destino fisico do backup

O fluxo de backup registra no log:

- repositorio configurado
- tipo do destino
- espaco livre inicial
- espaco livre final
- variacao de espaco livre

Para caminho UNC, o sistema informa explicitamente que o destino e de rede.

### Comandos operacionais uteis

Ver snapshots:

```powershell
$ResticExe = (Get-Command restic).Source
$RepositoryPath = 'E:\restic-backup'
$PasswordFilePath = 'C:\restic\runtime\secrets\restic-password.txt'

& $ResticExe snapshots --repo $RepositoryPath --password-file $PasswordFilePath
```

Check parcial:

```powershell
& $ResticExe check --read-data-subset=10% --repo $RepositoryPath --password-file $PasswordFilePath
```

Check completo:

```powershell
& $ResticExe check --repo $RepositoryPath --password-file $PasswordFilePath
```

## Padrao de Distribuicao

Ao preparar este projeto para outra maquina:

- distribua o codigo e a estrutura de pastas
- mantenha runtime/logs vazio ou descartavel
- mantenha runtime/secrets vazio na origem do pacote
- nao exporte token, senha ou repositorio de um cliente para outro
- execute install.bat ou setup/install.ps1 na maquina de destino
- registre variaveis e tarefas de forma local, por maquina

### Estrutura minima esperada no pacote

```text
README.md
install.bat
backup.bat
check.bat
sincronizar_externo.bat
ativar_agora.bat
centro_de_controle.bat
app/
setup/
tools/
runtime/
```

## Auditoria do Repositorio

Foi feita uma revisao do repositorio com foco em distribuicao e seguranca operacional.

### Situacao atual

- scripts principais sem credenciais reais hardcoded
- fluxo de aplicacao separado do estado local
- utilitarios com hardcodes pessoais removidos
- runtime isolado e ignorado por .gitignore
- senha local movida para runtime/secrets/
- logs movidos para runtime/logs/

### O que continua sendo responsabilidade operacional

- proteger ACL do arquivo de senha local
- garantir permissao da conta do scheduler ao repositorio
- evitar unidade mapeada quando a tarefa nao roda na mesma sessao interativa
- testar restore periodicamente

## Problemas Comuns

### Restic.exe nao encontrado

```powershell
(Get-Command restic).Source
.\setup\show_env.ps1
```

Se necessario, execute setup/setup_env.ps1 novamente com o caminho correto.

### A tarefa funciona manualmente, mas falha no horario

Verifique:

- conta configurada na tarefa
- ACL do arquivo de senha
- acesso da conta ao repositorio
- uso de unidade mapeada em vez de UNC
- configuracao da aba Conditions no Task Scheduler

### Telegram nao valida

Verifique:

- token correto
- se o bot ja recebeu /start
- se o chat informado existe e esta acessivel ao bot
- conectividade HTTPS da maquina

### Logs antigos aparecendo na raiz

O padrao atual usa runtime/logs/. Se houver arquivos antigos na raiz ou em logs/ legado, eles sao historicos anteriores a reorganizacao e podem ser arquivados ou removidos conforme a politica da equipe.

## Checklist de Go-Live

1. restic.exe validado com restic version
2. repositorio acessivel pela conta real da tarefa
3. arquivo de senha criado em runtime/secrets/ ou caminho corporativo equivalente
4. ACL do arquivo de senha revisada
5. Telegram validado, se aplicavel
6. setup/setup_env.ps1 executado com sucesso
7. setup/show_env.ps1 exibindo os caminhos esperados
8. backup.bat executado manualmente com sucesso
9. check.bat executado manualmente com sucesso
10. tarefa de backup criada e validada
11. tarefa de check criada e validada
12. pelo menos uma restauracao de teste planejada ou executada

## Referencias

- Restic: instalacao e operacao basica no Windows
- Telegram Bot API: BotFather, getMe, getUpdates e getChat
- Windows Task Scheduler: conta de execucao, privilegios e gatilhos
