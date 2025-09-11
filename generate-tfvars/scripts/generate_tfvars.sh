#!/bin/bash
set -e

echo "Gerando terraform.auto.tfvars.json a partir do script Bash externo..."

# Instala jq se não estiver presente (geralmente já está em runners ubuntu-latest)
if ! command -v jq &> /dev/null
then
    echo "jq não encontrado. Instalando..."
    sudo apt-get update && sudo apt-get install -y jq
fi

# Debug jq version para fins de diagnóstico futuro
echo "jq version: $(jq --version)"

# Garante que o diretório 'terraform' exista antes de tentar escrever o arquivo
mkdir -p terraform/

# --- TRATAMENTO PARA LAMBDA_MEMORY ---
# Define um valor padrão se LAMBDA_MEMORY estiver vazio
if [ -z "$LAMBDA_MEMORY" ]; then
  LAMBDA_MEMORY_PROCESSED="128" # Defina aqui o valor padrão desejado
  echo "LAMBDA_MEMORY estava vazia. Usando o valor padrão: $LAMBDA_MEMORY_PROCESSED"
else
  LAMBDA_MEMORY_PROCESSED="$LAMBDA_MEMORY"
  echo "LAMBDA_MEMORY: $LAMBDA_MEMORY_PROCESSED"
fi
# -----------------------------------

# Estratégia Robusta para JSONs Complexos:
# Converte o conteúdo JSON das variáveis de ambiente em literais de string JSON.
# Isso garante que as aspas internas e quebras de linha sejam escapadas corretamente,
# permitindo que o 'jq' as parseie com 'fromjson' sem erros de sintaxe do shell.
environments_json_literal=$(printf '%s' "$ENVIRONMENTS" | jq -sRr '.')
echo "DEBUG: environments_json_literal criado."
echo "Usando default global_env_vars_json_literal. == prod"
echo "$BRANCH_NAME"
global_env_vars_json_literal=$(printf '%s' "$GLOBAL_ENV_VARS_JSON" | jq -sRr '.')
# Usando variaveis de ambiente globais JSON baseado na branch
if [ "$BRANCH_NAME" == "develop" ]; then
  echo "Usando branch develop"
  echo "Modificando global_env_vars_json_literal para dev"
  global_env_vars_json_literal=$(printf '%s' "$GLOBAL_ENV_VARS_JSON_DEV" | jq -sRr '.')
elif [ "$BRANCH_NAME" == "sandbox" ]; then
  echo "Usando branch sandbox"
  echo "Modificando global_env_vars_json_literal para sandbox"
  global_env_vars_json_literal=$(printf '%s' "$GLOBAL_ENV_VARS_JSON_SANDBOX" | jq -sRr '.')
fi


# --- NOVAS VARIÁVEIS: Preparação para converter strings de IDs em arrays JSON ---
# Para LAMBDA_SUBNET_IDS
if [ -n "$LAMBDA_SUBNET_IDS" ]; then
  IFS=',' read -ra SUBNETS_ARRAY <<< "$LAMBDA_SUBNET_IDS"
  LAMBDA_SUBNET_IDS_JSON=$(printf '%s\n' "${SUBNETS_ARRAY[@]}" | jq -R . | jq -s .)
else
  LAMBDA_SUBNET_IDS_JSON="[]" # Se vazio, retorna array vazio para o Terraform
fi

# Para LAMBDA_SECURITY_GROUP_IDS
if [ -n "$LAMBDA_SECURITY_GROUP_IDS" ]; then
  IFS=',' read -ra SGS_ARRAY <<< "$LAMBDA_SECURITY_GROUP_IDS"
  LAMBDA_SECURITY_GROUP_IDS_JSON=$(printf '%s\n' "${SGS_ARRAY[@]}" | jq -R . | jq -s .)
else
  LAMBDA_SECURITY_GROUP_IDS_JSON="[]" # Se vazio, retorna array vazio para o Terraform
fi

# Debug dos literais de string JSON escapados e arrays formatados
echo "--- DEBUG (Script): environments_json_literal (escaped) ---"
echo "$environments_json_literal"
echo "--- DEBUG (Script): global_env_vars_json_literal (escaped) ---"
echo "$global_env_vars_json_literal"
echo "--- DEBUG (Script): LAMBDA_SUBNET_IDS_JSON (formatted) ---"
echo "$LAMBDA_SUBNET_IDS_JSON"
echo "--- DEBUG (Script): LAMBDA_SECURITY_GROUP_IDS_JSON (formatted) ---"
echo "$LAMBDA_SECURITY_GROUP_IDS_JSON"
echo "-------------------------------------------------------------"


# Constrói o JSON final usando jq.
# Para os JSONs complexos, usa --arg e depois 'fromjson' no filtro do jq.
# Para variáveis simples, usa --arg diretamente.
# Converte as strings "true"/"false" para booleanos nativos do JSON onde necessário.
json_content=$(jq -n \
  --arg environments_str "$environments_json_literal" \
  --arg global_env_vars_json_str "$global_env_vars_json_literal" \
  --arg s3_bucket_name_val "$S3_BUCKET_NAME" \
  --arg aws_region_val "$AWS_REGION" \
  --arg project_name_val "$PROJECT_NAME" \
  --arg environment_val "$ENVIRONMENT" \
  --arg create_sqs_queue_str "$CREATE_SQS_QUEUE" \
  --arg use_existing_sqs_trigger_str "$USE_EXISTING_SQS_TRIGGER" \
  --arg existing_sqs_queue_name_val "$EXISTING_SQS_QUEUE_NAME" \
  --arg lambda_vpc_id_val "$LAMBDA_VPC_ID" \
  --argjson lambda_subnet_ids_json "$LAMBDA_SUBNET_IDS_JSON" \
  --argjson lambda_security_group_ids_json "$LAMBDA_SECURITY_GROUP_IDS_JSON" \
  --arg lambda_timeout_str "$LAMBDA_TIMEOUT" \
  --arg lambda_memory_str "$LAMBDA_MEMORY_PROCESSED" \
  '{
    environments: ($environments_str | fromjson),
    global_env_vars: ($global_env_vars_json_str | fromjson),
    s3_bucket_name: $s3_bucket_name_val,
    aws_region: $aws_region_val,
    project_name: $project_name_val,
    environment: $environment_val,
    create_sqs_queue: ($create_sqs_queue_str | if . == "true" then true else false end),
    use_existing_sqs_trigger: ($use_existing_sqs_trigger_str | if . == "true" then true else false end),
    existing_sqs_queue_name: $existing_sqs_queue_name_val,
    # --- NOVAS VARIÁVEIS PARA O TERRAFORM ---
    lambda_vpc_id: $lambda_vpc_id_val,
    lambda_subnet_ids: $lambda_subnet_ids_json,
    lambda_security_group_ids: $lambda_security_group_ids_json,
    lambda_timeout: ($lambda_timeout_str | tonumber),
    lambda_memory: ($lambda_memory_str | tonumber)
  }')

# Debug: Imprime o resultado do jq antes de escrever no arquivo
echo "--- DEBUG (Script): Conteúdo da variável json_content antes de escrever ---"
echo "$json_content"
echo "------------------------------------------------------------------"

# Escreve o JSON gerado para o arquivo terraform.auto.tfvars.json
echo "$json_content" > terraform/terraform.auto.tfvars.json

# Limpa os arquivos temporários, se houver (nesta abordagem, não usamos, mas é um bom hábito)
# rm environments_input_temp.json global_env_vars_input_temp.json # Comentado, pois não são mais usados

echo "✅ terraform.auto.tfvars.json gerado com sucesso pelo script externo!"
