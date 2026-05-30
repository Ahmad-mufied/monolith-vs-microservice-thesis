# AWS Budget Nuclear Shutdown

## Purpose

Automated AWS resource shutdown triggered when monthly budget threshold is
reached. Prevents runaway costs from idle benchmark infrastructure.

## Architecture

```text
AWS Budget (monitor monthly cost)
    │
    ├── 50%  → email warning
    ├── 80%  → email warning
    ├── 95%  → email critical warning
    └── 100% → SNS topic → Lambda → nuclear shutdown
                                           │
                   ┌───────────────────────┼───────────────────────┐
                   ▼                       ▼                       ▼
           Delete EKS clusters      Stop RDS instances     Delete NAT GW
           (kedua cluster)          (kedua instance)       + release EIPs
```

Email notifications at 50%, 80%, and 95% are sent directly by AWS Budgets.
No confirmation step is required. At 100%, the SNS topic triggers the Lambda
function automatically.

## Configuration

All configuration is in `infra/terraform/shared/terraform.tfvars`:

```hcl
budget_amount            = 30    # monthly USD limit
budget_threshold_percent = 100   # nuclear shutdown at 100%
budget_alert_emails      = ["you@email.com"]
```

### Variables

| Variable | Type | Default | Description |
|---|---|---|---|
| `budget_amount` | `number` | `30` | Monthly budget in USD |
| `budget_threshold_percent` | `number` | `100` | Threshold to trigger nuclear shutdown |
| `budget_alert_emails` | `list(string)` | `[]` | Email addresses for alerts |

### Notification Tiers

| Threshold | Action | Channel |
|---|---|---|
| 50% | Email warning | Direct email from AWS Budgets |
| 80% | Email warning | Direct email from AWS Budgets |
| 95% | Email critical warning | Direct email from AWS Budgets |
| 100% | Nuclear shutdown | SNS topic → Lambda |

Budget name is descriptively set to
`skripsi-budget-auto-destroy-at-100pct` so the email context is clear.

## Setup Options

### Option A: Terraform (Recommended)

Budget is deployed automatically when running `make eks-shared-apply`. No
additional steps needed.

```text
make eks-shared-apply
  → VPC + IAM + Budget + Lambda + SNS (all in one apply)
```

S3 bucket and ECR repositories are created separately via `make aws-create-s3`
and `make aws-create-ecr`. They are not managed by Terraform, so no conflict
with the shared stack.

### Option B: Manual AWS CLI

If you prefer to set up the budget manually (independent of Terraform), follow
the steps below. This is useful when the shared Terraform stack is already
applied and you don't want to re-run it.

#### Prerequisites

| Tool | Purpose |
|---|---|
| AWS CLI | Deploy Lambda, SNS, Budget |
| Python 3.12 | Lambda runtime |
| `zip` | Package Lambda code |

#### Step 1: Create IAM Role

```bash
# Trust policy for Lambda
cat > /tmp/trust-policy.json << 'EOF'
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Principal": { "Service": "lambda.amazonaws.com" },
    "Action": "sts:AssumeRole"
  }]
}
EOF

# Create role
aws iam create-role \
  --role-name skripsi-budget-nuclear-shutdown-role \
  --assume-role-policy-document file:///tmp/trust-policy.json

# Attach policy
aws iam put-role-policy \
  --role-name skripsi-budget-nuclear-shutdown-role \
  --policy-name skripsi-budget-nuclear-shutdown-policy \
  --policy-document file://infra/terraform/modules/aws-budget/lambda/lambda_iam_policy.json
```

#### Step 2: Deploy Lambda Function

```bash
cd infra/terraform/modules/aws-budget/lambda
zip budget_nuclear_shutdown.zip budget_nuclear_shutdown.py

aws lambda create-function \
  --function-name skripsi-budget-nuclear-shutdown \
  --runtime python3.12 \
  --role arn:aws:iam::$(aws sts get-caller-identity --query Account --output text):role/skripsi-budget-nuclear-shutdown-role \
  --handler budget_nuclear_shutdown.lambda_handler \
  --zip-file fileb://budget_nuclear_shutdown.zip \
  --timeout 900 \
  --memory-size 256 \
  --region ap-southeast-1 \
  --environment "Variables={
    EKS_CLUSTERS=skripsi-monolith,skripsi-msa,
    RDS_INSTANCE_IDS=skripsi-monolith-postgres,skripsi-msa-postgres,
    VPC_ID=REPLACE_WITH_VPC_ID,
    DELETE_EKS=true,
    AWS_REGION=ap-southeast-1
  }"
```

Get your VPC ID:

```bash
aws ec2 describe-vpcs \
  --filters "Name=tag:Project,Values=skripsi" \
  --query 'Vpcs[0].VpcId' \
  --output text
```

#### Step 3: Create SNS Topic + Subscribe Lambda

```bash
# Create topic
TOPIC_ARN=$(aws sns create-topic \
  --name skripsi-budget-nuclear \
  --region ap-southeast-1 \
  --query 'TopicArn' \
  --output text)

echo "Topic ARN: $TOPIC_ARN"

# Get Lambda ARN
LAMBDA_ARN=$(aws lambda get-function \
  --function-name skripsi-budget-nuclear-shutdown \
  --query 'Configuration.FunctionArn' \
  --output text \
  --region ap-southeast-1)

# Subscribe Lambda to SNS
aws sns subscribe \
  --topic-arn $TOPIC_ARN \
  --protocol lambda \
  --notification-endpoint $LAMBDA_ARN \
  --region ap-southeast-1

# Allow SNS to invoke Lambda
aws lambda add-permission \
  --function-name skripsi-budget-nuclear-shutdown \
  --statement-id sns-invoke \
  --action lambda:InvokeFunction \
  --principal sns.amazonaws.com \
  --source-arn $TOPIC_ARN \
  --region ap-southeast-1
```

#### Step 4: Create AWS Budget

```bash
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)

cat > /tmp/budget.json << EOF
{
  "BudgetName": "skripsi-budget-auto-destroy-at-100pct",
  "BudgetType": "COST",
  "TimeUnit": "MONTHLY",
  "TimePeriod": {
    "Start": "2026-01-01T00:00:00Z",
    "End": "2087-06-15T00:00:00Z"
  },
  "BudgetLimit": {
    "Amount": "30",
    "Unit": "USD"
  }
}
EOF

cat > /tmp/notifications.json << EOF
[
  {
    "NotificationType": "ACTUAL",
    "ComparisonOperator": "GREATER_THAN",
    "Threshold": 50,
    "ThresholdType": "PERCENTAGE",
    "NotificationState": "ALARM",
    "Subscribers": [{
      "SubscriptionType": "EMAIL",
      "Address": "you@email.com"
    }]
  },
  {
    "NotificationType": "ACTUAL",
    "ComparisonOperator": "GREATER_THAN",
    "Threshold": 80,
    "ThresholdType": "PERCENTAGE",
    "NotificationState": "ALARM",
    "Subscribers": [{
      "SubscriptionType": "EMAIL",
      "Address": "you@email.com"
    }]
  },
  {
    "NotificationType": "ACTUAL",
    "ComparisonOperator": "GREATER_THAN",
    "Threshold": 95,
    "ThresholdType": "PERCENTAGE",
    "NotificationState": "ALARM",
    "Subscribers": [{
      "SubscriptionType": "EMAIL",
      "Address": "you@email.com"
    }]
  },
  {
    "NotificationType": "ACTUAL",
    "ComparisonOperator": "GREATER_THAN",
    "Threshold": 100,
    "ThresholdType": "PERCENTAGE",
    "NotificationState": "ALARM",
    "Subscribers": [{
      "SubscriptionType": "SNS",
      "Address": "$TOPIC_ARN"
    }]
  }
]
EOF

aws budgets create-budget \
  --account-id $ACCOUNT_ID \
  --budget file:///tmp/budget.json \
  --notifications-with-subscribers file:///tmp/notifications.json \
  --region ap-southeast-1
```

#### Step 5: Verify

```bash
# Check budget
aws budgets describe-budgets \
  --account-id $ACCOUNT_ID \
  --region ap-southeast-1

# Check Lambda
aws lambda get-function \
  --function-name skripsi-budget-nuclear-shutdown \
  --region ap-southeast-1

# Check SNS subscription
aws sns list-subscriptions-by-topic \
  --topic-arn $TOPIC_ARN \
  --region ap-southeast-1
```

#### Manual Cleanup (when thesis is done)

```bash
# Delete budget
aws budgets delete-budget \
  --account-id $ACCOUNT_ID \
  --budget-name skripsi-budget-auto-destroy-at-100pct

# Delete Lambda
aws lambda delete-function \
  --function-name skripsi-budget-nuclear-shutdown

# Delete SNS topic
aws sns delete-topic --topic-arn $TOPIC_ARN

# Delete IAM role (must delete policy first)
aws iam delete-role-policy \
  --role-name skripsi-budget-nuclear-shutdown-role \
  --policy-name skripsi-budget-nuclear-shutdown-policy
aws iam delete-role \
  --role-name skripsi-budget-nuclear-shutdown-role

# Delete CloudWatch log group
aws logs delete-log-group \
  --log-group-name /aws/lambda/skripsi-budget-nuclear-shutdown
```

## Shutdown Sequence

Lambda executes in this order:

```text
Step 1: Delete EKS Node Groups + Clusters
        for each cluster in [skripsi-monolith, skripsi-msa]:
          for each nodegroup:
            delete_nodegroup()
          wait_until_deleted()
          delete_cluster()

Step 2: Stop RDS Instances
        for each instance in [skripsi-monolith-postgres, skripsi-msa-postgres]:
          stop_db_instance()

Step 3: Delete NAT Gateways + Release Elastic IPs
        describe_nat_gateways(vpc_id)
        for each nat_gw:
          delete_nat_gateway()
        release EIPs associated with deleted NAT GWs
        release any unassociated EIPs in the account
```

### Error Handling

Each step handles errors independently. If one resource fails, the shutdown
continues with the remaining resources.

| Scenario | Handling |
|---|---|
| Cluster already deleted | Log warning, skip, continue |
| RDS already stopped | Log warning, skip, continue |
| NAT GW already deleted | Log info, skip, continue |
| Node group delete timeout | Log error, attempt cluster delete anyway |
| Partial failure | Return summary per step, operator cleans up manually |

## What Gets Shut Down

| Resource | Action | Billing | Data Safe? |
|---|---|---|---|
| EKS worker nodes | Deleted | Stopped | N/A |
| EKS clusters | Deleted | $0.10/hr × 2 saved | Etcd backup exists |
| RDS instances | Stopped | Compute stopped | Yes (storage persists) |
| NAT Gateway | Deleted | $0.045/hr saved | N/A |
| Elastic IPs | Released | $0.005/hr saved | N/A |
| S3 bucket | Not touched | Minimal | Yes |
| ECR repositories | Not touched | Minimal | Yes |

## Recovery

After nuclear shutdown, restore with Terraform:

```bash
make eks-apply
```

Terraform will recreate:

- EKS clusters + node groups
- RDS instances
- NAT Gateway
- Elastic IPs

RDS data persists through stop/start cycle. Application data is restored by
seed jobs during deployment.

If `terraform apply` fails because resources were deleted outside Terraform
state, use:

```bash
terraform refresh
terraform apply
```

## Testing

### Verify Budget Created

```bash
aws budgets describe-budgets \
  --account-id $(aws sts get-caller-identity --query Account --output text) \
  --region ap-southeast-1
```

### Verify Lambda Function

```bash
aws lambda get-function \
  --function-name skripsi-budget-nuclear-shutdown \
  --region ap-southeast-1
```

### Manual Lambda Invoke (DANGEROUS)

```bash
aws lambda invoke \
  --function-name skripsi-budget-nuclear-shutdown \
  --payload '{"source": "manual-test"}' \
  --region ap-southeast-1 \
  response.json

cat response.json
```

**Warning:** This will actually execute the shutdown. Only invoke when ready
to destroy infrastructure.

### View Lambda Logs

```bash
aws logs tail /aws/lambda/skripsi-budget-nuclear-shutdown \
  --follow \
  --region ap-southeast-1
```

## Terraform Resources Created

| Resource | Name | Purpose |
|---|---|---|
| `aws_budgets_budget.cost` | `skripsi-budget-auto-destroy-at-100pct` | Monthly cost monitor |
| `aws_sns_topic.budget_nuclear` | `skripsi-budget-nuclear` | Trigger channel for Lambda |
| `aws_sns_topic_subscription.nuclear_lambda` | — | SNS → Lambda subscription |
| `aws_lambda_function.shutdown` | `skripsi-budget-nuclear-shutdown` | Shutdown executor |
| `aws_lambda_permission.sns` | — | SNS invoke permission |
| `aws_iam_role.lambda` | `skripsi-budget-nuclear-shutdown-role` | Lambda execution role |
| `aws_iam_role_policy.lambda` | `skripsi-budget-nuclear-shutdown-policy` | EKS, RDS, EC2, Logs |
| `aws_cloudwatch_log_group.lambda` | `/aws/lambda/skripsi-budget-nuclear-shutdown` | Lambda logs (7 days) |
| `data.archive_file.lambda` | — | Lambda zip packaging |

## Cost After Shutdown

| Resource | Monthly Cost |
|---|---|
| EKS (deleted) | $0 |
| RDS (stopped) | ~$2-3 (storage only) |
| NAT GW (deleted) | $0 |
| S3 + ECR | ~$0.50 |
| **Total** | **~$3-4/month** |

## Source-of-Truth References

| Topic | Document |
|---|---|
| Cloud architecture overview | `docs/infrastructure/cloud-architecture.md` |
| EKS cluster design | `docs/infrastructure/eks-cluster-design.md` |
| Terraform runbook | `docs/infrastructure/terraform-runbook.md` |
| Budget module source | `infra/terraform/modules/aws-budget/` |
| Lambda source | `infra/terraform/modules/aws-budget/lambda/budget_nuclear_shutdown.py` |
