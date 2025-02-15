#!/bin/bash

display_help() {
  echo "Usage: $0 [OPTIONS] [STACK_NAME]"
  echo ""
  echo "Options:"
  echo "  --help                    Display this help message"
  echo "  --region                  Specify AWS region (default: from AWS config)"
  echo "  --simulate                Dry run - show commands that would be executed"
  echo "  --deploy                  Execute the deployment of stacks"
  echo "  --update                  Update existing stacks"
  echo "  --validate                Validate CloudFormation templates"
  echo "  --cleanup                 Remove deployed stacks"
  echo ""
  echo "Stack Operations:"
  echo "  Without [STACK_NAME]:     Operates on all stacks in correct order"
  echo "  With [STACK_NAME]:        Operates only on the specified stack"
  echo ""
  echo "Available Stack Names:"
  echo "  [sanitized]-domain          Domain and certificate management"
  echo "  [sanitized]-api-base        API base infrastructure"
  echo "  [sanitized]-api-mapping-v2  API Gateway mappings and routes"
  echo "  [sanitized]-workmail-v2     WorkMail Lambda integration with S3"
  echo ""
  echo "Examples:"
  echo "  $0 --deploy                     Deploy all stacks"
  echo "  $0 --deploy --[sanitized]-domain   Deploy only domain stack"
  echo "  $0 --deploy --[sanitized]-workmail-v2  Deploy only WorkMail stack"
  echo "  $0 --validate                   Validate all templates"
  echo "  $0 --region my-region --deploy  Deploy all stacks in EU West (Ireland)"
  echo ""
}

# --- Function to check stack status ---
check_stack_status() {
  local stack_name=$1
  local status=$(aws cloudformation describe-stacks --stack-name "$stack_name" --query 'Stacks.StackStatus' --output text 2>/dev/null)
  echo "$status"
}

# --- Function to check if stack exists ---
stack_exists() {
  local stack_name=$1
  aws cloudformation describe-stacks --stack-name "$stack_name" >/dev/null 2>&1
  return $?
}

# --- Function to wait for certificate validation ---
wait_for_certificate_validation() {
  local cert_arn=$1
  local max_attempts=60  # 30 minutes maximum wait time
  local attempt=1

  echo "Waiting for ACM certificate validation..."
  while [ $attempt -le $max_attempts ]; do
    local status=$(aws acm describe-certificate --certificate-arn "$cert_arn" --query 'Certificate.Status' --output text)
    
    if [ "$status" = "ISSUED" ]; then
      echo "Certificate validated successfully"
      return 0
    elif [ "$status" = "FAILED" ]; then
      echo "Certificate validation failed"
      return 1
    fi
    
    echo "Certificate status: $status (attempt $attempt of $max_attempts)"
    sleep 30
    ((attempt++))
  done
  
  echo "Timeout waiting for certificate validation"
  return 1
}

# --- Function to deploy or update workmail stack using SAM ---
deploy_workmail_stack() {
  local cmd=$1
  echo "${cmd}ing workmail stack..."

  # Fetch WorkMail Organization ID
  echo "Retrieving WorkMail Organization ID..."
  local org_id=$(aws workmail list-organizations --query 'OrganizationSummaries.OrganizationId' --output text)
   
  if [[ -z "$org_id" ]]; then
    echo "Error: No WorkMail organization found"
    exit 1
  fi
  echo "Using WorkMail Organization ID: ${org_id}"
  
  if [[ "$MODE" = "deploy" || "$MODE" = "update" ]]; then
    cd "${WORK_DIR}"
    if [[ -f "packaged.yaml" ]]; then
      rm packaged.yaml
    fi

    # Verify SAM bucket exists before packaging
    if! aws s3api head-bucket --bucket "${SAM_BUCKET}" 2>/dev/null; then
      echo "Error: SAM deployment bucket ${SAM_BUCKET} does not exist"
      exit 1
    fi

    echo "Packaging SAM template..."
    if! sam package \
      --template-file workmail-inbound.yaml \
      --output-template-file packaged.yaml \
      --s3-bucket "${SAM_BUCKET}" \
      --s3-prefix "${SAM_ARTIFACTS_PREFIX}" \
      --region "${AWS_REGION}"; then
      echo "Failed to package SAM template"
      exit 1
    fi

    if [! -f packaged.yaml ]; then
      echo "Error: SAM packaging did not produce packaged.yaml"
      exit 1
    fi

    echo "Deploying SAM application..."
    local deploy_cmd="sam deploy \
      --template-file packaged.yaml \
      --stack-name [sanitized]-workmail-v2 \
      --capabilities CAPABILITY_IAM \
      --parameter-overrides OrganizationId=${org_id} \
      --region ${AWS_REGION} \
      --no-fail-on-empty-changeset"

    if! $deploy_cmd; then
      echo "Failed to ${cmd} SAM application"
      exit 1
    fi

    workmail_status=$(check_stack_status "[sanitized]-workmail-v2")
    if [[ "$workmail_status"!= *"COMPLETE" ]]; then
      echo "WorkMail stack ${cmd} failed with status: $workmail_status"
      exit 1
    fi
  else
    echo "sam package --template-file workmail-inbound.yaml --output-template-file packaged.yaml --s3-bucket ${SAM_BUCKET} --region ${AWS_REGION}"
    echo "sam deploy --template-file packaged.yaml --stack-name [sanitized]-workmail-v2 --capabilities CAPABILITY_IAM --parameter-overrides OrganizationId=${org_id} --region ${AWS_REGION} --no-fail-on-empty-changeset"
  fi
}

# --- Function to deploy or update base stack ---
deploy_base_stack() {
  local cmd=$1
  echo "${cmd}ing base stack..."

  # Verify template exists
  if [! -f "${WORK_DIR}/api-base.yaml" ]; then
    echo "Error: API base stack template not found at ${WORK_DIR}/api-base.yaml"
    exit 1
  fi

  if [[ "$MODE" = "deploy" || "$MODE" = "update" ]]; then
    if [[ "$cmd" = "deploy" ]]; then
      eval "$BASE_STACK_CREATE_CMD" || exit 1
      aws cloudformation wait stack-create-complete --stack-name [sanitized]-api-base
    else
      eval "$BASE_STACK_UPDATE_CMD" || exit 1
      aws cloudformation wait stack-update-complete --stack-name [sanitized]-api-base
    fi

    base_status=$(check_stack_status "[sanitized]-api-base")
    if [[ "$base_status"!= *"COMPLETE" ]]; then
      echo "Base stack ${cmd} failed with status: $base_status"
      exit 1
    fi
  else
    if [[ "$cmd" = "deploy" ]]; then
      echo "$BASE_STACK_CREATE_CMD"
    else
      echo "$BASE_STACK_UPDATE_CMD"
    fi
    echo "aws cloudformation wait stack-${cmd}-complete --stack-name [sanitized]-api-base"
  fi
}

# --- Function to deploy or update domain stack ---
deploy_domain_stack() {
  local cmd=$1
  echo "${cmd}ing domain stack..."

  # Verify template exists
  if [! -f "${WORK_DIR}/domain-stack.yaml" ]; then
    echo "Error: Domain stack template not found at ${WORK_DIR}/domain-stack.yaml"
    exit 1
  fi

  if [[ "$MODE" = "deploy" || "$MODE" = "update" ]]; then
    if [[ "$cmd" = "deploy" ]]; then
      eval "$DOMAIN_STACK_CREATE_CMD" || exit 1
      aws cloudformation wait stack-create-complete --stack-name [sanitized]-domain
    else
      eval "$DOMAIN_STACK_UPDATE_CMD" || exit 1
      aws cloudformation wait stack-update-complete --stack-name [sanitized]-domain
    fi

    domain_status=$(check_stack_status "[sanitized]-domain")
    if [[ "$domain_status"!= *"COMPLETE" ]]; then
      echo "Domain stack ${cmd} failed with status: $domain_status"
      exit 1
    fi
  else
    if [[ "$cmd" = "deploy" ]]; then
      echo "$DOMAIN_STACK_CREATE_CMD"
    else
      echo "$DOMAIN_STACK_UPDATE_CMD"
    fi
    echo "aws cloudformation wait stack-${cmd}-complete --stack-name [sanitized]-domain"
  fi
}

# --- Function to cleanup individual stack ---
cleanup_stack() {
  local stack_name=$1
  
  # Special handling for WorkMail stack as it includes S3 bucket
  if [[ "$stack_name" == "[sanitized]-workmail-v2" ]]; then
    local bucket_name=$(aws cloudformation describe-stacks \
      --stack-name "$stack_name" \
      --query 'Stacks.Outputs[?OutputKey==`UpdatedEmailS3BucketName`].OutputValue' \
      --output text 2>/dev/null)
    
    if [[ -n "$bucket_name" ]]; then
      echo "Emptying S3 bucket $bucket_name before deletion..."
      aws s3 rm "s3://${bucket_name}" --recursive || true
      echo "Waiting for bucket to empty..."
      sleep 10  # Give some time for deletion to propagate
    fi
  fi
  
  echo "Deleting $stack_name stack..."
  aws cloudformation delete-stack --stack-name "$stack_name" --region "${AWS_REGION}" 2>/dev/null || true
  echo "Waiting for $stack_name stack deletion..."
  aws cloudformation wait stack-delete-complete --stack-name "$stack_name" --region "${AWS_REGION}" 2>/dev/null || true
  
  if aws cloudformation describe-stacks --stack-name "$stack_name" --region "${AWS_REGION}" 2>/dev/null; then
    echo "Warning: Stack $stack_name may not have been fully deleted"
    return 1
  fi
  echo "Stack $stack_name deleted successfully"
}

# --- Parse command-line options ---
MODE=""
STACK_NAME=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --help)
      display_help
      exit 0
  ;;
    --region)
      AWS_REGION="$2"
      shift 2
  ;;
    --simulate)
      MODE="simulate"
      shift
  ;;
    --deploy)
      MODE="deploy"
      shift
  ;;
    --update)
      MODE="update"
      shift
  ;;
    --validate)
      MODE="validate"
      shift
  ;;
    --cleanup)
      MODE="cleanup"
      shift
  ;;
    --[sanitized]-domain)
      STACK_NAME="[sanitized]-domain"
      shift
  ;;
    --[sanitized]-api-base)
      STACK_NAME="[sanitized]-api-base"
      shift
  ;;
    --[sanitized]-api-mapping-v2)
      STACK_NAME="[sanitized]-api-mapping-v2"
      shift
  ;;
    --[sanitized]-workmail-v2)
      STACK_NAME="[sanitized]-workmail-v2"
      shift
  ;;
    *)
      echo "Unknown option: $1"
      display_help
      exit 1
  ;;
  esac
done

# --- Get and display AWS region ---
if [[ -z "${AWS_REGION}" ]]; then
  AWS_REGION=$(aws configure get region)
fi
echo "AWS Region: ${AWS_REGION}"

export AWS_DEFAULT_REGION="${AWS_REGION}"

# --- Set the working directory ---
WORK_DIR=$(pwd)
echo "Working directory: ${WORK_DIR}"

# --- Set the domain name ---
DOMAIN_NAME="check.example.com"
echo "Domain name: ${DOMAIN_NAME}"

# --- Get AWS Account ID ---
AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text) || exit 1
echo "Using AWS Account ID: ${AWS_ACCOUNT_ID}"

# --- Set default SAM deployment bucket ---
SAM_BUCKET="[sanitized]-api-${AWS_ACCOUNT_ID}"
SAM_ARTIFACTS_PREFIX="artifacts"
#echo "Default SAM deployment bucket: ${SAM_BUCKET}"
echo "Using SAM deployment bucket: ${SAM_BUCKET}/${SAM_ARTIFACTS_PREFIX}"

if [[ "$STACK_NAME" == "[sanitized]-workmail-v2" ]]; then
  # Retrieve WorkMail stack's S3 bucket if it exists
  if stack_exists "[sanitized]-workmail-v2"; then
    WORKMAIL_BUCKET=$(aws cloudformation describe-stacks \
      --stack-name [sanitized]-workmail-v2 \
      --query 'Stacks.Outputs[?OutputKey==`UpdatedEmailS3BucketName`].OutputValue' \
      --output text 2>/dev/null)
    
    if [[ -n "$WORKMAIL_BUCKET" ]]; then
      #SAM_BUCKET="<span class="math-inline">WORKMAIL\_BUCKET"
SAM\_BUCKET\="[sanitized]\-api\-</span>{AWS_ACCOUNT_ID}"
      echo "Using SAM deployment bucket: <span class="math-inline">\{SAM\_BUCKET\}/</span>{SAM_ARTIFACTS_PREFIX}"
    fi
  fi

  # Check if SAM deployment bucket exists and create if needed
  if! aws s3api head-bucket --bucket "${SAM_BUCKET}" 2>/dev/null; then
    echo "Creating SAM deployment bucket: ${SAM_BUCKET}"
    if [[ "$MODE" = "deploy" || "<span class="math-inline">MODE" \= "update" \]\]; then
aws s3 mb "s3\://</span>{SAM_BUCKET}" --region "<span class="math-inline">\{AWS\_REGION\}"
\# Wait for bucket to be available
echo "Waiting for bucket to be available\.\.\."
aws s3api wait bucket\-exists \-\-bucket "</span>{SAM_BUCKET}"
      
      # Add versioning (recommended for deployment buckets)
      aws s3api put-bucket-versioning \
        --bucket "<span class="math-inline">\{SAM\_BUCKET\}" \\
\-\-versioning\-configuration Status\=Enabled
\# Block public access
aws s3api put\-public\-access\-block \\
\-\-bucket "</span>{SAM_BUCKET}" \
        --public-access-block-configuration \
          "BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true"
    else
      echo "Would create SAM deployment bucket: <span class="math-inline">\{SAM\_BUCKET\}"
fi
fi
fi
\# \-\-\- Get and store the hosted zone ID \-\-\-
echo "Retrieving Hosted Zone ID\.\.\."
HOSTED\_ZONE\_ID\=</span>(aws route53 list-hosted-zones-by-name \
  --dns-name example.com \
  --query 'HostedZones.Id' \
  --output text | cut -d'/' -f3) || exit 1
echo "Hosted Zone ID: ${HOSTED_ZONE_ID}"

# --- Handle cleanup mode ---
if [[ "$MODE" = "cleanup" ]]; then
  if [[ -n "$STACK_NAME" ]]; then
    cleanup_stack "$STACK_NAME"
    echo "Cleanup of $STACK_NAME completed!"
  else
    echo "Cleaning up all stacks..."
    cleanup_stack "[sanitized]-api-mapping-v2"
    cleanup_stack "[sanitized]-workmail-v2"
    cleanup_stack "[sanitized]-api-base"
    cleanup_stack "[sanitized]-domain"
    echo "Cleanup of all stacks completed!"
  fi
  exit 0
fi

# --- Validate and deploy/simulate/update ---
if [[ "$MODE" = "deploy" || "$MODE" = "simulate" || "$MODE" = "update" || "$MODE" = "validate" ]]; then
  # Get current AWS credentials
  echo "Retrieving current AWS credentials..."
  if [[ "$MODE"!= "simulate" && "$MODE"!= "validate" ]]; then
    aws sts get-caller-identity || exit 1
  else
    echo "aws sts get-caller-identity"
  fi

  # Deployment confirmation for actual deployment or update
  if [[ "$MODE" = "deploy" || "$MODE" = "update" ]]; then
    read -p "Proceed with <span class="math-inline">\{MODE\}? \[Y/n\]\: " CONFIRM
if \[\[ "</span>{CONFIRM}" == "n" ]]; then
      echo "<span class="math-inline">\{MODE\} aborted\."
exit 1
fi
fi
\# Set up stack commands
DOMAIN\_STACK\_CREATE\_CMD\="aws cloudformation create\-stack \\
\-\-stack\-name [sanitized]\-domain \\
\-\-template\-body \\"file\://</span>{WORK_DIR}/domain-stack.yaml\" \
    --parameters \
        ParameterKey=DomainName,ParameterValue=<span class="math-inline">\{DOMAIN\_NAME\} \\
ParameterKey\=HostedZoneId,ParameterValue\=</span>{HOSTED_ZONE_ID}"

  DOMAIN_STACK_UPDATE_CMD="aws cloud
formation update-stack \
    --stack-name [sanitized]-domain \
    --template-body \"file://${WORK_DIR}/domain-stack.yaml\" \
    --parameters \
        ParameterKey=DomainName,ParameterValue=${DOMAIN_NAME} \
        ParameterKey=HostedZoneId,ParameterValue=${HOSTED_ZONE_ID}"

  BASE_STACK_CREATE_CMD="aws cloudformation create-stack \
    --stack-name [sanitized]-api-base \
    --template-body \"file://${WORK_DIR}/api-base.yaml\" \
    --parameters \
        ParameterKey=Environment,ParameterValue=prod \
        ParameterKey=DebugMode,ParameterValue=false \
        ParameterKey=DomainStackName,ParameterValue=[sanitized]-domain \
        ParameterKey=[sanitized],ParameterValue=[sanitized]ApiKey \
    --capabilities CAPABILITY_IAM"

  BASE_STACK_UPDATE_CMD="aws cloudformation update-stack \
    --stack-name [sanitized]-api-base \
    --template-body \"file://${WORK_DIR}/api-base.yaml\" \
    --parameters \
        ParameterKey=Environment,ParameterValue=prod \
        ParameterKey=DebugMode,ParameterValue=false \
        ParameterKey=DomainStackName,ParameterValue=[sanitized]-domain \
        ParameterKey=[sanitized],ParameterValue=[sanitized]ApiKey \
    --capabilities CAPABILITY_IAM"

  if [[ "$MODE" = "validate" ]]; then
    echo "Validating CloudFormation templates..."
    if [[ -n "$STACK_NAME" ]]; then
      case "$STACK_NAME" in
        "[sanitized]-domain")
          echo "Validating domain stack template..."
          aws cloudformation validate-template --template-body "file://${WORK_DIR}/domain-stack.yaml"
        ;;
        "[sanitized]-api-base")
          echo "Validating API base stack template..."
          aws cloudformation validate-template --template-body "file://${WORK_DIR}/api-base.yaml"
        ;;
        "[sanitized]-api-mapping-v2")
          echo "Validating API mapping stack template..."
          aws cloudformation validate-template --template-body "file://${WORK_DIR}/api-mapping.yaml"
        ;;
        "[sanitized]-workmail-v2")
          echo "Validating WorkMail SAM template..."
          sam validate --template workmail-inbound.yaml
        ;;
      esac
      echo "Template validation completed!"
      exit 0
    else
      echo "Validating all templates..."
      echo "Validating domain stack template..."
      aws cloudformation validate-template --template-body "file://${WORK_DIR}/domain-stack.yaml"
      echo "Validating API base stack template..."
      aws cloudformation validate-template --template-body "file://${WORK_DIR}/api-base.yaml"
      echo "Validating API mapping stack template..."
      aws cloudformation validate-template --template-body "file://${WORK_DIR}/api-mapping.yaml"
      echo "Validating WorkMail SAM template..."
      sam validate --template workmail-inbound.yaml
      echo "All templates validated successfully!"
      exit 0
    fi
  fi

  # Handle individual stack deployment/update or full deployment/update
  if [[ -n "$STACK_NAME" ]]; then
    case "$STACK_NAME" in
      "[sanitized]-domain")
        if stack_exists "$STACK_NAME" && [[ "$MODE" = "update" ]]; then
          deploy_domain_stack "update"
        else
          deploy_domain_stack "deploy"
        fi
      ;;
      "[sanitized]-api-base")
        if stack_exists "$STACK_NAME" && [[ "$MODE" = "update" ]]; then
          deploy_base_stack "update"
        else
          deploy_base_stack "deploy"
        fi
      ;;
      "[sanitized]-api-mapping-v2")
        if stack_exists "$STACK_NAME" && [[ "$MODE" = "update" ]]; then
          deploy_mapping_stack "update"
        else
          deploy_mapping_stack "deploy"
        fi
      ;;
      "[sanitized]-workmail-v2")   
        if stack_exists "$STACK_NAME" && [[ "$MODE" = "update" ]]; then
          deploy_workmail_stack "update"
        else
          deploy_workmail_stack "deploy"
        fi
      ;;
    esac
    echo "${MODE} of $STACK_NAME completed successfully!"
  else
    # Deploy/Update all stacks in order
    if stack_exists "[sanitized]-domain" && [[ "$MODE" = "update" ]]; then
      deploy_domain_stack "update"
    else
      deploy_domain_stack "deploy"
    fi

    if stack_exists "[sanitized]-api-base" && [[ "$MODE" = "update" ]]; then
      deploy_base_stack "update"
    else
      deploy_base_stack "deploy"
    fi

    if stack_exists "[sanitized]-api-mapping-v2" && [[ "$MODE" = "update" ]]; then
      deploy_mapping_stack "update"
    else
      deploy_mapping_stack "deploy"
    fi

    if stack_exists "[sanitized]-workmail-v2" && [[ "$MODE" = "update" ]]; then
      deploy_workmail_stack "update"
    else
      deploy_workmail_stack "deploy"
    fi
    
    echo "${MODE} of all stacks completed successfully!"
  fi
else
  echo "No valid mode selected. Use --deploy, --simulate, --update, --validate, or --cleanup"
  display_help
  exit 1
fi
}