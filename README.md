# cpanel-quota-adjustment
Script Bash para gerenciamento de quotas cPanel/WHM. Calcula a quota com base no uso atual + 1 GB, permite simulação, aplicação real, inclusão de contas ilimitadas, filtros por usuário, limite de contas e geração de logs.


Script Bash desenvolvido para automatizar o gerenciamento de quotas de contas em servidores cPanel/WHM.

O script consulta o uso de disco das contas, identifica suas quotas atuais e calcula uma nova quota com base no uso atual, adicionando 1 GB de margem.

Principais recursos:

Consulta automática do uso das contas via WHM API.
Cálculo de quota baseado em uso atual + 1 GB.
Quota mínima de 1 GB.
Modo de simulação, sem realizar alterações.
Modo de aplicação real com --apply.
Suporte para inclusão de contas atualmente ilimitadas.
Teste por usuários específicos com --usuarios.
Limitação da quantidade de contas processadas com --limit.
Exibição do impacto total das alterações de quota.
Verificação do espaço físico disponível no servidor.
Registro das operações em /var/log/ajuste_quotas.log.
Identificação de contas que serão aumentadas, reduzidas ou mantidas.
Exemplo
# Simulação
./ajuste_quotas.sh


# Testar duas contas
./ajuste_quotas.sh --limit=2


# Testar incluindo contas ilimitadas
./ajuste_quotas.sh --limit=2 --incluir-ilimitadas


# Aplicar em todas as contas
./ajuste_quotas.sh --apply


# Aplicar incluindo contas ilimitadas
./ajuste_quotas.sh --incluir-ilimitadas --apply

Recomendação: utilizar primeiro o modo de simulação e testar algumas contas antes de executar alterações em todo o servidor.
