# Lab 10 — Route 53 DNSSEC Validation Failure

## Overview

This lab demonstrates how to troubleshoot DNS resolution failures caused by DNSSEC validation in Amazon Route 53 Resolver.

We deploy an Amazon EC2 instance inside a dedicated AWS VPC and configure Route 53 Resolver DNSSEC validation.

We use `dnssec-failed.org`, a public domain intentionally configured with broken DNSSEC, to reproduce a DNS validation failure.

Before enabling DNSSEC validation, the domain generally resolves successfully. After enabling DNSSEC validation, Route 53 Resolver rejects the invalid DNS response and returns `SERVFAIL`.

We investigate the failure using AWS CLI, Linux DNS utilities, DNSSEC records, and public DNS resolvers.

We examine how DNSKEY, DS, and RRSIG records contribute to the DNSSEC chain of trust.

We also perform a controlled diagnostic comparison by temporarily disabling validation inside the disposable lab VPC. After confirming the behavior, we enable DNSSEC validation again.

Finally, we remove all temporary AWS resources.

**Troubleshooting Workflow:**

VPC Setup → EC2 Deployment → Baseline DNS Testing → Enable DNSSEC Validation → Reproduce SERVFAIL → Investigate DNSSEC → Root Cause Analysis → Controlled Verification → Restore DNSSEC → Cleanup

---

## 1. Lab Information

| Item | Configuration |
|---|---|
| Incident ID | INC-R53-010 |
| Difficulty | Advanced |
| AWS Region | `us-east-1` |
| AWS Services | Route 53 Resolver, EC2, VPC, IAM, Systems Manager |
| Local Environment | WSL Ubuntu |
| Operating System | Amazon Linux 2023 |
| EC2 Instance Type | `t3.micro` |
| VPC CIDR | `10.63.0.0/16` |
| Public Subnet | `10.63.1.0/24` |
| VPC DNS Resolver | `10.63.0.2` |
| DNSSEC Test Domain | `dnssec-failed.org` |
| Healthy Comparison Domain | `cloudflare.com` |
| DNS Record Type | A |
| Fault Scenario | DNSSEC validation failure |
| Expected DNS Error | SERVFAIL |
| Root Cause | Invalid DNSSEC authentication chain |
| Diagnostic Comparison | Validation enabled vs. disabled |
| Production Remediation | Repair DNSSEC signing or delegation |
| Verification Tools | AWS CLI, dig, getent |
| EC2 Management | AWS Systems Manager |

---

## 2. Production Incident Scenario

### Incident Description

A company hosts its applications inside AWS.

The applications use Amazon Route 53 Resolver to resolve public DNS hostnames.

The company's security team enables DNSSEC validation inside an AWS VPC to improve DNS response authenticity.

Shortly after enabling DNSSEC validation, one application cannot resolve an external domain.

The application reports a DNS resolution error.

When the Cloud Engineer investigates using Linux `dig`, the DNS query returns:

```text
status: SERVFAIL
```

However, other public domains continue resolving successfully.

The engineer initially suspects an EC2 networking issue, security group restriction, or Route 53 Resolver outage.

Further investigation reveals that the affected domain has an invalid DNSSEC authentication chain.

Route 53 Resolver is correctly rejecting the invalid DNS response.

The engineer must identify the underlying DNSSEC problem and determine the appropriate remediation.

### Incident Symptoms

- EC2 instance is running.
- VPC DNS support is enabled.
- Route 53 Resolver is operational.
- Other public domains resolve successfully.
- DNSSEC validation is enabled.
- The affected domain returns SERVFAIL.
- DNS responses are rejected because DNSSEC authentication fails.
- Temporarily disabling DNSSEC validation in the disposable VPC changes the observed behavior.
- Re-enabling validation causes the invalid domain to be rejected again.

### Business Impact

- Applications may fail to connect to affected external services.
- DNS-dependent application functionality can become unavailable.
- Monitoring may report DNS lookup failures.
- Users may experience application errors.
- Engineers may mistakenly troubleshoot healthy network infrastructure.
- Disabling DNSSEC without investigating can weaken DNS security.

### Objective

Identify a DNSSEC validation failure, distinguish it from ordinary DNS or networking problems, and understand how to correct the underlying DNSSEC configuration in a production environment.

**Important:** This lab does not repair `dnssec-failed.org`. The domain is intentionally broken and is used only to demonstrate DNSSEC validation behavior.

---

## 3. AWS Architecture

### Infrastructure Architecture

```text
                    AWS Region
                     us-east-1
                         |
                         v
                    Amazon VPC
                  10.63.0.0/16
                         |
                         v
                    Public Subnet
                   10.63.1.0/24
                         |
                         v
                    EC2 Instance
                 Amazon Linux 2023
                         |
                         v
                    DNS Query
                         |
                         v
                 Route 53 Resolver
                    10.63.0.2
                         |
                         v
                 DNSSEC Validation
                       ENABLED
                         |
                -------------------
                |                 |
                v                 v
          Healthy Domain     Broken DNSSEC
          cloudflare.com     dnssec-failed.org
                |                 |
                v                 v
           Valid Response    Invalid DNSSEC
                |                 |
                v                 v
              NOERROR           SERVFAIL
```

### DNSSEC Authentication Architecture

```text
                    DNS Root
                       |
                       v
                Root Trust Anchor
                       |
                       v
                  Parent Zone
                     (.org)
                       |
                       v
                    DS Record
                       |
                       v
                   Child Zone
                dnssec-failed.org
                       |
                       v
                    DNSKEY
                       |
                       v
                    RRSIG
                       |
                       v
                DNSSEC Validation
                       |
                       v
             Authentication Failure
                       |
                       v
                    SERVFAIL
```

### Before Enabling DNSSEC Validation

```text
EC2 DNS Client
       |
       v
Route 53 Resolver
       |
       v
DNSSEC Validation Disabled
       |
       v
DNS Query for dnssec-failed.org
       |
       v
DNS Answer May Be Returned
       |
       v
NOERROR
```

### After Enabling DNSSEC Validation

```text
EC2 DNS Client
       |
       v
Route 53 Resolver
       |
       v
DNSSEC Validation Enabled
       |
       v
DNS Query for dnssec-failed.org
       |
       v
DNSSEC Authentication Failure
       |
       v
DNS Response Rejected
       |
       v
SERVFAIL
```

### Network Configuration

| Component | Configuration |
|---|---|
| VPC | `10.63.0.0/16` |
| Public Subnet | `10.63.1.0/24` |
| Internet Gateway | Attached |
| Default Route | `0.0.0.0/0` |
| EC2 Operating System | Amazon Linux 2023 |
| EC2 Public IP | Assigned by AWS |
| VPC Resolver | `10.63.0.2` |
| DNS Protocol | UDP/TCP 53 |
| EC2 Administration | Systems Manager |
| SSH | Not required |

No public hosted zone, purchased domain, or Route 53 Resolver endpoint is required.

---

## 4. Understanding DNSSEC

### What Is DNSSEC?

DNSSEC stands for Domain Name System Security Extensions.

It adds cryptographic authentication to DNS responses.

DNSSEC helps validating resolvers determine whether DNS data is authentic and has not been modified.

### Why Is DNSSEC Important?

Traditional DNS does not inherently authenticate DNS responses.

An attacker may attempt to provide forged DNS information.

DNSSEC helps prevent acceptance of forged or incorrectly signed DNS data.

### Important DNSSEC Records

| Record | Purpose |
|---|---|
| DNSKEY | Publishes a public key used for DNSSEC verification |
| DS | Connects a parent zone to a child zone's DNSSEC key |
| RRSIG | Provides a cryptographic signature for a DNS record set |
| NSEC | Provides authenticated proof that a record does not exist |
| NSEC3 | Provides an alternative form of authenticated denial of existence |

### What Is DNSKEY?

DNSKEY contains a DNSSEC public key.

Validating resolvers use the public key to verify appropriate DNSSEC signatures.

### What Is a DS Record?

DS stands for Delegation Signer.

It is published in a parent zone and links the parent zone's trust chain to the child zone's DNSSEC key.

For example:

```text
Root Zone
    |
    v
.org
    |
    v
DS Record
    |
    v
example.org
```

### What Is RRSIG?

RRSIG contains a digital signature associated with a DNS record set.

A validating resolver can use the appropriate DNSKEY to verify the signature.

### What Is a DNSSEC Chain of Trust?

A DNSSEC chain of trust connects verified parent-zone information to the keys and signed records of child zones.

Simplified:

```text
Trusted Root Key
       |
       v
Parent DS
       |
       v
Child DNSKEY
       |
       v
RRSIG Verification
       |
       v
Authenticated DNS Response
```

If an expected secure chain cannot be verified, a validating resolver can reject the DNS response.

### What Is SERVFAIL?

SERVFAIL is a DNS response code indicating that the DNS server could not successfully complete the requested operation.

DNSSEC authentication failure is one possible cause.

Other possible causes include DNS server problems, forwarding errors, authoritative server failures, and network problems.

Therefore, SERVFAIL alone does not prove that DNSSEC is broken.

### Does DNSSEC Encrypt DNS?

No.

DNSSEC provides authentication and integrity for DNS data.

It does not provide confidentiality.

DNS over HTTPS and DNS over TLS address different security properties.

---

## 5. Prerequisites and Safety

### Requirements

- AWS account
- AWS CLI v2
- WSL Ubuntu
- Bash
- EC2 permissions
- VPC permissions
- IAM permissions
- Route 53 Resolver permissions
- Systems Manager access
- Linux dig
- Git and GitHub

### Security Rules

- Use a dedicated disposable VPC.
- Do not change DNSSEC settings in production.
- Do not modify real domains or registrar records.
- Do not disable DNSSEC as a permanent troubleshooting solution.
- Use Systems Manager instead of inbound SSH.
- Do not commit AWS credentials.
- Review evidence files before publishing.
- Delete all temporary resources after the exercise.

### Cost Considerations

This lab may incur AWS charges for the EC2 instance, EBS storage, and public IPv4 address.

No paid Route 53 Resolver outbound endpoint is required.

---

## 6. Prepare WSL Ubuntu

### Step 1 — Verify AWS CLI

```bash
aws --version
aws sts get-caller-identity
```

### Step 2 — Configure Variables

```bash
export AWS_REGION="us-east-1"
export AWS_PAGER=""

export PROJECT_TAG="Route53-Troubleshooting-Lab10"

export VPC_CIDR="10.63.0.0/16"
export SUBNET_CIDR="10.63.1.0/24"

export VPC_DNS="10.63.0.2"

export BROKEN_DOMAIN="dnssec-failed.org"
export HEALTHY_DOMAIN="cloudflare.com"

export EC2_ROLE_NAME="route53-lab10-ssm-role"
export PROFILE_NAME="route53-lab10-ssm-profile"

export SG_NAME="route53-lab10-client-sg"
```

### Step 3 — Verify Variables

```bash
echo "$AWS_REGION"
echo "$VPC_CIDR"
echo "$VPC_DNS"
echo "$BROKEN_DOMAIN"
echo "$HEALTHY_DOMAIN"
```

Keep the WSL terminal open to preserve resource IDs.

---

## 7. Create VPC and Subnet

### Step 1 — Create VPC

```bash
export VPC_ID=$(aws ec2 create-vpc \
  --cidr-block "$VPC_CIDR" \
  --tag-specifications \
  "ResourceType=vpc,Tags=[{Key=Name,Value=route53-lab10-vpc},{Key=Project,Value=$PROJECT_TAG}]" \
  --query 'Vpc.VpcId' \
  --output text \
  --region "$AWS_REGION")

echo "$VPC_ID"
```

### Step 2 — Enable DNS Support

```bash
aws ec2 modify-vpc-attribute \
  --vpc-id "$VPC_ID" \
  --enable-dns-support \
  --region "$AWS_REGION"

aws ec2 modify-vpc-attribute \
  --vpc-id "$VPC_ID" \
  --enable-dns-hostnames \
  --region "$AWS_REGION"
```

### Step 3 — Verify DNS Settings

```bash
aws ec2 describe-vpc-attribute \
  --vpc-id "$VPC_ID" \
  --attribute enableDnsSupport \
  --region "$AWS_REGION"

aws ec2 describe-vpc-attribute \
  --vpc-id "$VPC_ID" \
  --attribute enableDnsHostnames \
  --region "$AWS_REGION"
```

Expected: both settings are enabled.

### Step 4 — Check Supported Availability Zones

```bash
aws ec2 describe-instance-type-offerings \
  --location-type availability-zone \
  --filters "Name=instance-type,Values=t3.micro" \
  --query 'InstanceTypeOfferings[].Location' \
  --output table \
  --region "$AWS_REGION"
```

Choose a supported AZ:

```bash
export AZ="us-east-1a"
```

Change it if your account does not support `t3.micro` in that zone.

### Step 5 — Create Public Subnet

```bash
export SUBNET_ID=$(aws ec2 create-subnet \
  --vpc-id "$VPC_ID" \
  --cidr-block "$SUBNET_CIDR" \
  --availability-zone "$AZ" \
  --tag-specifications \
  "ResourceType=subnet,Tags=[{Key=Name,Value=route53-lab10-public},{Key=Project,Value=$PROJECT_TAG}]" \
  --query 'Subnet.SubnetId' \
  --output text \
  --region "$AWS_REGION")

echo "$SUBNET_ID"
```

---

## 8. Configure Internet Gateway and Routing

### Step 1 — Create Internet Gateway

```bash
export IGW_ID=$(aws ec2 create-internet-gateway \
  --tag-specifications \
  "ResourceType=internet-gateway,Tags=[{Key=Name,Value=route53-lab10-igw},{Key=Project,Value=$PROJECT_TAG}]" \
  --query 'InternetGateway.InternetGatewayId' \
  --output text \
  --region "$AWS_REGION")
```

### Step 2 — Attach Internet Gateway

```bash
aws ec2 attach-internet-gateway \
  --internet-gateway-id "$IGW_ID" \
  --vpc-id "$VPC_ID" \
  --region "$AWS_REGION"
```

### Step 3 — Create Route Table

```bash
export ROUTE_TABLE_ID=$(aws ec2 create-route-table \
  --vpc-id "$VPC_ID" \
  --tag-specifications \
  "ResourceType=route-table,Tags=[{Key=Name,Value=route53-lab10-public-rt},{Key=Project,Value=$PROJECT_TAG}]" \
  --query 'RouteTable.RouteTableId' \
  --output text \
  --region "$AWS_REGION")
```

### Step 4 — Create Internet Route

```bash
aws ec2 create-route \
  --route-table-id "$ROUTE_TABLE_ID" \
  --destination-cidr-block 0.0.0.0/0 \
  --gateway-id "$IGW_ID" \
  --region "$AWS_REGION"
```

### Step 5 — Associate Subnet

```bash
export ROUTE_ASSOC_ID=$(aws ec2 associate-route-table \
  --route-table-id "$ROUTE_TABLE_ID" \
  --subnet-id "$SUBNET_ID" \
  --query AssociationId \
  --output text \
  --region "$AWS_REGION")
```

---

## 9. Create Security Group and IAM Role

### Step 1 — Create Security Group

```bash
export SG_ID=$(aws ec2 create-security-group \
  --group-name "$SG_NAME" \
  --description "Route53 Lab10 DNSSEC troubleshooting client" \
  --vpc-id "$VPC_ID" \
  --tag-specifications \
  "ResourceType=security-group,Tags=[{Key=Name,Value=$SG_NAME},{Key=Project,Value=$PROJECT_TAG}]" \
  --query GroupId \
  --output text \
  --region "$AWS_REGION")

echo "$SG_ID"
```

No inbound rules are necessary.

### Step 2 — Create IAM Trust Policy

Save as `ec2-trust-policy.json`:

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "Service": "ec2.amazonaws.com"
      },
      "Action": "sts:AssumeRole"
    }
  ]
}
```

### Step 3 — Create IAM Role

```bash
aws iam create-role \
  --role-name "$EC2_ROLE_NAME" \
  --assume-role-policy-document file://ec2-trust-policy.json \
  --tags Key=Project,Value="$PROJECT_TAG"

aws iam attach-role-policy \
  --role-name "$EC2_ROLE_NAME" \
  --policy-arn arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore
```

### Step 4 — Create Instance Profile

```bash
aws iam create-instance-profile \
  --instance-profile-name "$PROFILE_NAME" \
  --tags Key=Project,Value="$PROJECT_TAG"

aws iam add-role-to-instance-profile \
  --instance-profile-name "$PROFILE_NAME" \
  --role-name "$EC2_ROLE_NAME"
```

Allow IAM propagation before launching EC2.

---

## 10. Deploy EC2 DNS Troubleshooting Client

### Step 1 — Create User Data

Save as `user-data.sh`:

```bash
#!/bin/bash
set -euxo pipefail

dnf install -y bind-utils curl

mkdir -p /opt/route53-lab10

echo "Route 53 DNSSEC troubleshooting client" \
  > /opt/route53-lab10/README.txt
```

### Step 2 — Retrieve Amazon Linux AMI

```bash
export AMI_ID=$(aws ssm get-parameter \
  --name "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64" \
  --query Parameter.Value \
  --output text \
  --region "$AWS_REGION")

echo "$AMI_ID"
```

### Step 3 — Launch EC2

```bash
export INSTANCE_ID=$(aws ec2 run-instances \
  --image-id "$AMI_ID" \
  --instance-type t3.micro \
  --subnet-id "$SUBNET_ID" \
  --security-group-ids "$SG_ID" \
  --associate-public-ip-address \
  --iam-instance-profile "Name=$PROFILE_NAME" \
  --user-data file://user-data.sh \
  --metadata-options "HttpTokens=required,HttpEndpoint=enabled" \
  --tag-specifications \
  "ResourceType=instance,Tags=[{Key=Name,Value=route53-lab10-dns-client},{Key=Project,Value=$PROJECT_TAG}]" \
  --query 'Instances[0].InstanceId' \
  --output text \
  --region "$AWS_REGION")

echo "$INSTANCE_ID"
```

### Step 4 — Wait for EC2

```bash
aws ec2 wait instance-running \
  --instance-ids "$INSTANCE_ID" \
  --region "$AWS_REGION"

aws ec2 wait instance-status-ok \
  --instance-ids "$INSTANCE_ID" \
  --region "$AWS_REGION"
```

### Step 5 — Connect Through Systems Manager

```bash
aws ssm start-session \
  --target "$INSTANCE_ID" \
  --region "$AWS_REGION"
```

Inside EC2, install DNS utilities if necessary:

```bash
sudo dnf install -y bind-utils
```

Set variables:

```bash
export VPC_DNS="10.63.0.2"
export BROKEN_DOMAIN="dnssec-failed.org"
export HEALTHY_DOMAIN="cloudflare.com"
```

---

## 11. Baseline DNS Testing

Before enabling DNSSEC validation, verify ordinary DNS resolution.

### Step 1 — Query Healthy Domain

Inside EC2:

```bash
dig @"$VPC_DNS" "$HEALTHY_DOMAIN" A
```

Expected:

```text
status: NOERROR
```

One or more A records should appear.

### Step 2 — Query Broken DNSSEC Domain

```bash
dig @"$VPC_DNS" "$BROKEN_DOMAIN" A
```

With DNSSEC validation disabled, the expected result is generally:

```text
status: NOERROR
```

Record the actual output rather than assuming the result.

### Step 3 — Save Baseline Evidence

```bash
dig @"$VPC_DNS" "$HEALTHY_DOMAIN" A \
  > "$HOME/lab10-baseline-healthy.txt"

dig @"$VPC_DNS" "$BROKEN_DOMAIN" A \
  > "$HOME/lab10-baseline-broken.txt"
```

Exit EC2:

```bash
exit
```

### Step 4 — Verify Initial DNSSEC Configuration

From WSL:

```bash
aws route53resolver get-resolver-dnssec-config \
  --resource-id "$VPC_ID" \
  --output json \
  --region "$AWS_REGION"
```

Expected: validation is disabled.

If the baseline already returns SERVFAIL, investigate the effective validation configuration before proceeding.

---

## 12. Fault Injection — Enable DNSSEC Validation

### Step 1 — Enable DNSSEC Validation

From WSL:

```bash
aws route53resolver update-resolver-dnssec-config \
  --resource-id "$VPC_ID" \
  --validation ENABLE \
  --region "$AWS_REGION"
```

### Step 2 — Verify Validation Status

```bash
aws route53resolver get-resolver-dnssec-config \
  --resource-id "$VPC_ID" \
  --query 'ResolverDNSSECConfig.{VPC:ResourceId,Status:ValidationStatus}' \
  --output table \
  --region "$AWS_REGION"
```

Expected after the configuration takes effect:

```text
ENABLED
```

### Step 3 — Connect to EC2

```bash
aws ssm start-session \
  --target "$INSTANCE_ID" \
  --region "$AWS_REGION"
```

Inside EC2:

```bash
export VPC_DNS="10.63.0.2"
export BROKEN_DOMAIN="dnssec-failed.org"
export HEALTHY_DOMAIN="cloudflare.com"
```

### Step 4 — Reproduce DNSSEC Failure

```bash
dig @"$VPC_DNS" "$BROKEN_DOMAIN" A
```

Expected:

```text
status: SERVFAIL
```

### Step 5 — Test With DNSSEC Flag

```bash
dig @"$VPC_DNS" "$BROKEN_DOMAIN" A +dnssec
```

Expected: SERVFAIL.

### Step 6 — Test Checking Disabled Flag

```bash
dig @"$VPC_DNS" "$BROKEN_DOMAIN" A +cd
```

Expected: SERVFAIL.

Route 53 VPC Resolver ignores the DNSSEC checking-disabled flag, so `+cd` does not bypass its DNSSEC validation.

### Step 7 — Compare With Healthy Domain

```bash
dig @"$VPC_DNS" "$HEALTHY_DOMAIN" A
```

Expected:

```text
status: NOERROR
```

This shows that general DNS resolution is still functioning.

### Step 8 — Verify Linux DNS Resolution

```bash
getent ahostsv4 "$BROKEN_DOMAIN"
```

Expected: no usable address through the validating VPC Resolver.

### Step 9 — Inspect System Resolver

```bash
cat /etc/resolv.conf
```

Confirm the instance uses the expected VPC DNS path.

### Step 10 — Save Failure Evidence

```bash
dig @"$VPC_DNS" "$BROKEN_DOMAIN" A \
  > "$HOME/lab10-before-servfail.txt"

dig @"$VPC_DNS" "$HEALTHY_DOMAIN" A \
  > "$HOME/lab10-control-healthy.txt"
```

Exit:

```bash
exit
```

### Expected Fault Injection Results

| Test | Expected |
|---|---|
| VPC DNSSEC Validation | ENABLED |
| Broken Domain | SERVFAIL |
| Healthy Domain | NOERROR |
| EC2 Status | Running |
| VPC DNS Support | Enabled |
| Root Cause | Invalid DNSSEC authentication |

---

## 13. AWS CLI Troubleshooting Investigation

### Check 1 — Inspect DNSSEC Configuration

From WSL:

```bash
aws route53resolver get-resolver-dnssec-config \
  --resource-id "$VPC_ID" \
  --output json \
  --region "$AWS_REGION"
```

Expected: validation enabled.

### Check 2 — Save DNSSEC Configuration

```bash
aws route53resolver get-resolver-dnssec-config \
  --resource-id "$VPC_ID" \
  --output json \
  --region "$AWS_REGION" \
  > lab10-dnssec-enabled.json
```

### Check 3 — Verify VPC DNS Support

```bash
aws ec2 describe-vpc-attribute \
  --vpc-id "$VPC_ID" \
  --attribute enableDnsSupport \
  --region "$AWS_REGION"
```

Expected: true.

### Check 4 — Verify VPC DNS Hostnames

```bash
aws ec2 describe-vpc-attribute \
  --vpc-id "$VPC_ID" \
  --attribute enableDnsHostnames \
  --region "$AWS_REGION"
```

Expected: true.

### Check 5 — Compare DNS Responses

The comparison should show that the affected domain fails while the healthy domain continues resolving.

| Investigation | Expected Finding |
|---|---|
| EC2 Instance | Running |
| VPC Resolver | Operational |
| DNS Support | Enabled |
| DNSSEC Validation | Enabled |
| Broken Domain | SERVFAIL |
| Healthy Domain | NOERROR |
| Complete DNS Outage | No |

---

## 14. Investigate DNSSEC Records

### Step 1 — Query a Public Validating Resolver

From WSL:

```bash
dig @8.8.8.8 dnssec-failed.org A
```

Expected:

```text
status: SERVFAIL
```

### Step 2 — Query With Checking Disabled

```bash
dig @8.8.8.8 dnssec-failed.org A +cd
```

Expected, if the public resolver honors the flag and the network permits the request:

```text
status: NOERROR
```

Google Public DNS supports the checking-disabled flag.

If external DNS requests time out, that may indicate a network restriction and should not be treated as proof of DNSSEC failure.

### Step 3 — Inspect DNSKEY Records

```bash
dig @8.8.8.8 dnssec-failed.org DNSKEY +cd +dnssec
```

DNSKEY publishes the public keys used in DNSSEC verification.

### Step 4 — Inspect DS Records

```bash
dig @8.8.8.8 dnssec-failed.org DS +cd +dnssec
```

DS records are maintained in the parent zone and establish the trust link to the child zone.

### Step 5 — Inspect Signed DNS Responses

```bash
dig @8.8.8.8 dnssec-failed.org A +cd +dnssec
```

Look for available RRSIG data and other DNSSEC-related records.

Seeing DNSSEC records does not by itself prove that their cryptographic signatures are valid.

### Step 6 — Save Evidence

```bash
dig @8.8.8.8 dnssec-failed.org A \
  > lab10-public-validation-failed.txt

dig @8.8.8.8 dnssec-failed.org A +cd \
  > lab10-public-checking-disabled.txt

dig @8.8.8.8 dnssec-failed.org DNSKEY +cd +dnssec \
  > lab10-dnskey.txt

dig @8.8.8.8 dnssec-failed.org DS +cd +dnssec \
  > lab10-ds.txt
```

### Investigation Summary

| Investigation | Expected Result |
|---|---|
| Route 53 Validating Resolver | SERVFAIL |
| Public Validating Resolver | SERVFAIL |
| Public Resolver With CD | Generally NOERROR |
| Healthy Control Domain | NOERROR |
| DNSKEY | Available for inspection |
| DS | Available for inspection |
| DNSSEC Chain | Invalid for test domain |

---

## 15. Root Cause Analysis

### Root Cause

The external domain `dnssec-failed.org` has an intentionally broken DNSSEC authentication chain.

When Route 53 Resolver DNSSEC validation is enabled, it attempts to verify the authenticity of DNS responses.

Because the domain's DNSSEC authentication fails, Route 53 Resolver rejects the response and returns SERVFAIL.

The failure is not caused by EC2, the VPC route table, or an application server.

Route 53 Resolver is enforcing its security configuration.

### Root Cause Flow

```text
Application DNS Request
          |
          v
Route 53 Resolver
          |
          v
DNSSEC Validation Enabled
          |
          v
Retrieve DNS Records
          |
          v
Verify DNSSEC Chain
          |
          v
Invalid Authentication
          |
          v
Reject DNS Response
          |
          v
SERVFAIL
```

### Five Whys

1. **Why did the hostname fail?** Route 53 Resolver returned SERVFAIL.
2. **Why was SERVFAIL returned?** DNSSEC validation failed.
3. **Why did DNSSEC validation fail?** The domain has an intentionally broken DNSSEC authentication chain.
4. **Why did other domains resolve?** They did not trigger the same DNSSEC validation failure.
5. **What is the correct production solution?** Repair the affected domain's DNSSEC signing or delegation.

### Root Cause Summary

| Item | Finding |
|---|---|
| Incident | INC-R53-010 |
| AWS Service | Route 53 Resolver |
| Symptom | SERVFAIL |
| VPC Networking | Working |
| DNSSEC Validation | Enabled |
| Broken Domain | dnssec-failed.org |
| Root Cause | Invalid DNSSEC authentication |
| EC2 Redeployment | Not required |
| Correct Production Fix | DNSSEC signing/delegation repair |

**Important:** A DNSSEC SERVFAIL can indicate that a security control is functioning correctly.

---

## 16. Controlled Diagnostic Comparison

Because we do not own `dnssec-failed.org`, we cannot repair its authoritative DNSSEC configuration.

Instead, we perform a controlled comparison inside our disposable VPC.

This is a diagnostic experiment, not a production remediation recommendation.

### Step 1 — Temporarily Disable DNSSEC Validation

From WSL:

```bash
aws route53resolver update-resolver-dnssec-config \
  --resource-id "$VPC_ID" \
  --validation DISABLE \
  --region "$AWS_REGION"
```

### Step 2 — Verify Disabled Status

```bash
aws route53resolver get-resolver-dnssec-config \
  --resource-id "$VPC_ID" \
  --query 'ResolverDNSSECConfig.ValidationStatus' \
  --output text \
  --region "$AWS_REGION"
```

Expected:

```text
DISABLED
```

### Step 3 — Reconnect to EC2

```bash
aws ssm start-session \
  --target "$INSTANCE_ID" \
  --region "$AWS_REGION"
```

### Step 4 — Query the Broken Domain Again

Inside EC2:

```bash
dig @10.63.0.2 dnssec-failed.org A
```

Expected after validation is disabled:

```text
status: NOERROR
```

This demonstrates that DNSSEC validation was responsible for rejecting the response.

It does not prove the returned DNS data is trustworthy.

### Step 5 — Save Comparison Evidence

```bash
dig @10.63.0.2 dnssec-failed.org A \
  > "$HOME/lab10-validation-disabled.txt"
```

Exit:

```bash
exit
```

### Step 6 — Restore DNSSEC Validation

From WSL:

```bash
aws route53resolver update-resolver-dnssec-config \
  --resource-id "$VPC_ID" \
  --validation ENABLE \
  --region "$AWS_REGION"
```

### Step 7 — Verify Validation Restored

```bash
aws route53resolver get-resolver-dnssec-config \
  --resource-id "$VPC_ID" \
  --query 'ResolverDNSSECConfig.ValidationStatus' \
  --output text \
  --region "$AWS_REGION"
```

Expected:

```text
ENABLED
```

### Step 8 — Final DNS Verification

Connect:

```bash
aws ssm start-session \
  --target "$INSTANCE_ID" \
  --region "$AWS_REGION"
```

Inside EC2:

```bash
dig @10.63.0.2 cloudflare.com A
```

Expected: NOERROR.

```bash
dig @10.63.0.2 dnssec-failed.org A
```

Expected: SERVFAIL.

Exit:

```bash
exit
```

### Diagnostic Comparison

| Check | DNSSEC Disabled | DNSSEC Enabled |
|---|---|---|
| Healthy Domain | NOERROR | NOERROR |
| Broken Domain | Generally NOERROR | SERVFAIL |
| DNSSEC Authentication | Not enforced | Enforced |
| Invalid DNS Data | May be returned | Rejected |
| Security | Reduced | Stronger authentication |

The final diagnostic state should have DNSSEC validation enabled.

---

## 17. Correct Production Remediation

### DNSSEC Troubleshooting Checklist

1. Identify the affected domain.
2. Verify the SERVFAIL response.
3. Compare results using a known validating resolver.
4. Investigate the domain's DNSKEY records.
5. Investigate parent-zone DS records.
6. Examine RRSIG records and expiration times.
7. Verify the DNSSEC chain of trust.
8. Check the authoritative DNS provider's signing status.
9. Investigate key rollover issues.
10. Check registrar or parent-zone delegation.
11. Repair the broken signing or delegation configuration.
12. Verify successful DNSSEC validation.
13. Document the incident and remediation.

### Common DNSSEC Problems

| Problem | Correct Remediation |
|---|---|
| DS record does not match DNSKEY | Correct parent DS record |
| Expired RRSIG | Regenerate valid signatures |
| Missing DNSKEY | Restore correct signing keys |
| Interrupted key rollover | Complete the rollover safely |
| Incorrect registrar delegation | Correct DS configuration |
| Route 53 KSK problem | Investigate KSK and AWS KMS |
| DNSSEC disabled at provider but DS remains | Correct the parent delegation safely |

### Route 53 DNSSEC Signing Investigation

For a public hosted zone that you own:

```bash
aws route53 get-dnssec \
  --hosted-zone-id YOUR_PUBLIC_HOSTED_ZONE_ID
```

This returns information about DNSSEC signing and key-signing keys.

It is not a command to execute against the unrelated test domain.

### AWS KMS Considerations

Route 53 DNSSEC signing uses key-signing keys backed by AWS KMS.

If a KMS key becomes inaccessible or incorrectly configured, DNSSEC signing can be affected.

### Security Recommendation

Do not disable DNSSEC validation permanently just to eliminate SERVFAIL.

Instead, identify and repair the authoritative DNSSEC problem. Any temporary reduction in DNSSEC validation should be a deliberate security decision with appropriate approval.

---

## 18. AWS Resource Cleanup

**Warning:** Verify AWS resource IDs before deletion. These commands remove only the disposable Lab 10 infrastructure.

### Step 1 — Disable DNSSEC on Lab VPC Before Deletion

```bash
aws route53resolver update-resolver-dnssec-config \
  --resource-id "$VPC_ID" \
  --validation DISABLE \
  --region "$AWS_REGION"
```

Verify:

```bash
aws route53resolver get-resolver-dnssec-config \
  --resource-id "$VPC_ID" \
  --query 'ResolverDNSSECConfig.ValidationStatus' \
  --output text \
  --region "$AWS_REGION"
```

Wait until the result is:

```text
DISABLED
```

### Step 2 — Verify EC2 Root Volume

```bash
aws ec2 describe-instances \
  --instance-ids "$INSTANCE_ID" \
  --query 'Reservations[0].Instances[0].BlockDeviceMappings' \
  --output json \
  --region "$AWS_REGION"
```

Confirm root EBS `DeleteOnTermination=true`.

### Step 3 — Terminate EC2

```bash
aws ec2 terminate-instances \
  --instance-ids "$INSTANCE_ID" \
  --region "$AWS_REGION"

aws ec2 wait instance-terminated \
  --instance-ids "$INSTANCE_ID" \
  --region "$AWS_REGION"
```

### Step 4 — Verify IAM Role Ownership

```bash
aws iam list-role-tags \
  --role-name "$EC2_ROLE_NAME"
```

Confirm it belongs to Lab 10.

### Step 5 — Delete IAM Resources

```bash
aws iam detach-role-policy \
  --role-name "$EC2_ROLE_NAME" \
  --policy-arn arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore

aws iam remove-role-from-instance-profile \
  --instance-profile-name "$PROFILE_NAME" \
  --role-name "$EC2_ROLE_NAME"

aws iam delete-instance-profile \
  --instance-profile-name "$PROFILE_NAME"

aws iam delete-role \
  --role-name "$EC2_ROLE_NAME"
```

### Step 6 — Verify Network Interfaces

```bash
aws ec2 describe-network-interfaces \
  --filters "Name=vpc-id,Values=$VPC_ID" \
  --query 'NetworkInterfaces[].{ID:NetworkInterfaceId,Status:Status}' \
  --output table \
  --region "$AWS_REGION"
```

Wait until the EC2 network interface is removed.

### Step 7 — Delete Security Group

```bash
aws ec2 delete-security-group \
  --group-id "$SG_ID" \
  --region "$AWS_REGION"
```

### Step 8 — Disassociate Route Table

```bash
aws ec2 disassociate-route-table \
  --association-id "$ROUTE_ASSOC_ID" \
  --region "$AWS_REGION"
```

### Step 9 — Delete Route Table

```bash
aws ec2 delete-route-table \
  --route-table-id "$ROUTE_TABLE_ID" \
  --region "$AWS_REGION"
```

### Step 10 — Delete Subnet

```bash
aws ec2 delete-subnet \
  --subnet-id "$SUBNET_ID" \
  --region "$AWS_REGION"
```

### Step 11 — Detach Internet Gateway

```bash
aws ec2 detach-internet-gateway \
  --internet-gateway-id "$IGW_ID" \
  --vpc-id "$VPC_ID" \
  --region "$AWS_REGION"
```

### Step 12 — Delete Internet Gateway

```bash
aws ec2 delete-internet-gateway \
  --internet-gateway-id "$IGW_ID" \
  --region "$AWS_REGION"
```

### Step 13 — Delete VPC

```bash
aws ec2 delete-vpc \
  --vpc-id "$VPC_ID" \
  --region "$AWS_REGION"
```

### Step 14 — Verify Cleanup

```bash
aws ec2 describe-vpcs \
  --filters "Name=tag:Project,Values=$PROJECT_TAG" \
  --query 'Vpcs[].VpcId' \
  --output json \
  --region "$AWS_REGION"
```

Expected:

```json
[]
```

Also confirm the EC2 instance is terminated, the root EBS volume is deleted, and the IAM resources are removed.

### Cleanup Summary

| Resource | Expected Result |
|---|---|
| DNSSEC Lab VPC Configuration | Disabled before deletion |
| EC2 Instance | Terminated |
| EBS Root Volume | Deleted |
| IAM Role | Deleted |
| Instance Profile | Deleted |
| Security Group | Deleted |
| Route Table | Deleted |
| Subnet | Deleted |
| Internet Gateway | Deleted |
| Lab VPC | Deleted |
| Production Resources | Unchanged |

---

## 19. Interview Questions and Answers

### Q1. What is DNSSEC?

DNSSEC provides cryptographic authentication for DNS records and helps validating resolvers detect invalid or modified responses.

### Q2. Does DNSSEC encrypt DNS traffic?

No. DNSSEC provides authentication and integrity, not confidentiality.

### Q3. What is SERVFAIL?

A DNS response indicating that the DNS server could not successfully complete the query. DNSSEC validation failure is one possible cause.

### Q4. What is a DNSKEY record?

A DNS record that publishes a public key used to verify DNSSEC signatures.

### Q5. What is a DS record?

A Delegation Signer record that links a parent zone to a child zone's DNSSEC key.

### Q6. What is RRSIG?

A DNSSEC record containing a digital signature for a DNS record set.

### Q7. What is the DNSSEC chain of trust?

A sequence of cryptographic relationships connecting trusted root keys, parent DS records, child DNSKEY records, and signed DNS data.

### Q8. Why does dnssec-failed.org return SERVFAIL?

It is intentionally configured with broken DNSSEC authentication so that validating resolvers reject its responses.

### Q9. How do you enable DNSSEC validation in a VPC?

```bash
aws route53resolver update-resolver-dnssec-config \
  --resource-id VPC_ID \
  --validation ENABLE \
  --region us-east-1
```

### Q10. How do you inspect VPC DNSSEC validation?

```bash
aws route53resolver get-resolver-dnssec-config \
  --resource-id VPC_ID \
  --region us-east-1
```

### Q11. Does dig +cd bypass Route 53 VPC Resolver validation?

No. Route 53 VPC Resolver ignores the checking-disabled bit.

### Q12. How would you explain this lab in an interview?

I deployed an EC2 DNS troubleshooting client inside a dedicated AWS VPC and enabled Amazon Route 53 Resolver DNSSEC validation.

I used an intentionally DNSSEC-broken public domain to reproduce a SERVFAIL response.

I verified that normal DNS resolution still worked by querying a healthy comparison domain.

I investigated the DNSSEC validation configuration, tested a public validating DNS resolver, and examined DNSKEY and DS records.

I temporarily disabled validation inside the disposable lab VPC to compare DNS responses and confirm the security-related cause.

I then restored DNSSEC validation and verified that invalid DNS responses were rejected again.

I learned that DNSSEC SERVFAIL can indicate a correctly functioning security control and that production remediation requires repairing the domain's signing or delegation.

Finally, I deleted the temporary AWS resources.

---

## 20. Repository Structure

```text
aws-route53-troubleshooting-labs/
│
├── README.md
│
├── 01-dns-record-not-resolving/
│   └── README.md
│
├── 02-wrong-a-record/
│   └── README.md
│
├── 03-cname-misconfiguration/
│   └── README.md
│
├── 04-dns-ttl-caching-problem/
│   └── README.md
│
├── 05-public-vs-private-hosted-zone/
│   └── README.md
│
├── 06-incorrect-alias-record/
│   └── README.md
│
├── 07-route53-health-check-failure/
│   └── README.md
│
├── 08-dns-failover-not-working/
│   └── README.md
│
├── 09-resolver-rules-misconfiguration/
│   └── README.md
│
└── 10-dnssec-validation-failure/
    ├── README.md
    ├── ec2-trust-policy.json
    ├── user-data.sh
    ├── lab10-dnssec-enabled.json
    ├── lab10-public-validation-failed.txt
    ├── lab10-public-checking-disabled.txt
    ├── lab10-dnskey.txt
    └── lab10-ds.txt
```

### File Descriptions

| File | Purpose |
|---|---|
| `README.md` | Complete DNSSEC troubleshooting documentation |
| `ec2-trust-policy.json` | IAM trust policy for EC2 |
| `user-data.sh` | Installs Linux DNS troubleshooting utilities |
| `lab10-dnssec-enabled.json` | Captures enabled DNSSEC configuration |
| `lab10-public-validation-failed.txt` | Records DNS validation failure |
| `lab10-public-checking-disabled.txt` | Records public resolver response with CD flag |
| `lab10-dnskey.txt` | Captures DNSKEY investigation |
| `lab10-ds.txt` | Captures DS record investigation |

### Optional EC2 Evidence

```text
lab10-baseline-healthy.txt
lab10-baseline-broken.txt
lab10-before-servfail.txt
lab10-control-healthy.txt
lab10-validation-disabled.txt
```

These evidence files must be generated using real command output from your own lab.

Copy any EC2-based evidence you want to preserve before terminating the instance.

Review and sanitize evidence files before publishing them on GitHub.

---

## 21. Lessons Learned and Skills Demonstrated

### Lessons Learned

This lab demonstrates how DNSSEC validation protects AWS workloads by rejecting DNS responses that cannot be authenticated.

We created a dedicated AWS VPC and deployed an Amazon Linux EC2 instance for DNS troubleshooting.

We verified normal DNS resolution before enabling DNSSEC validation.

We then enabled Route 53 Resolver DNSSEC validation and queried an intentionally broken DNSSEC domain.

The resolver returned SERVFAIL because the domain's DNSSEC authentication chain was invalid.

We compared the failure against a healthy public domain to verify that general DNS resolution was working.

We also investigated DNSSEC records using public DNS utilities and compared the behavior of validating and nonvalidating resolution.

A controlled experiment inside the disposable VPC confirmed that DNSSEC validation was responsible for rejecting the invalid answer.

After verification, we restored DNSSEC validation and removed all temporary AWS infrastructure.

**Key Lesson:** DNSSEC validation failures should be investigated as potential DNS security issues, not automatically treated as networking problems. Disabling validation may change the response but does not repair an invalid DNSSEC chain.

### Skills Demonstrated

- Amazon Route 53 Resolver
- DNSSEC validation
- DNS security troubleshooting
- DNSKEY records
- DS records
- RRSIG records
- DNSSEC chain of trust
- SERVFAIL investigation
- DNS response authentication
- AWS CLI v2
- Linux dig
- Linux getent
- Public DNS resolver comparisons
- Amazon VPC
- EC2 troubleshooting
- AmazonProvidedDNS
- AWS Systems Manager
- IAM roles and instance profiles
- Root cause analysis
- Security configuration verification
- AWS resource cleanup

### Final Outcome

| Item | Expected Result |
|---|---|
| Incident | INC-R53-010 |
| Scenario | DNSSEC Validation Failure |
| DNSSEC Validation | Enabled during fault reproduction |
| Broken Domain | dnssec-failed.org |
| Healthy Domain | cloudflare.com |
| Broken Domain Response | SERVFAIL |
| Healthy Domain Response | NOERROR |
| Root Cause | Invalid DNSSEC authentication chain |
| Diagnostic Comparison | Validation enabled vs. disabled |
| Actual Domain Repair | Not performed |
| Correct Production Solution | Repair DNSSEC signing or delegation |
| DNSSEC Security Control | Restored after diagnostic testing |
| Cleanup | Temporary infrastructure removed |
| Incident Status | Diagnosed and verified |

**Key Takeaway:** Route 53 DNSSEC validation helps protect applications against invalid DNS data. A SERVFAIL response can indicate that the resolver is correctly rejecting an unauthenticated DNS answer. Engineers should investigate DNSSEC signing, DNSKEY, DS records, and delegation before changing security settings.

---

## Official References

- [AWS — Enabling DNSSEC Validation](https://docs.aws.amazon.com/Route53/latest/DeveloperGuide/resolver-dnssec-validation.html)
- [AWS — Troubleshooting DNSSEC](https://docs.aws.amazon.com/Route53/latest/DeveloperGuide/dns-configuring-dnssec-troubleshoot.html)
- [AWS CLI — Update Resolver DNSSEC Configuration](https://docs.aws.amazon.com/cli/latest/reference/route53resolver/update-resolver-dnssec-config.html)
- [AWS CLI — Get Resolver DNSSEC Configuration](https://docs.aws.amazon.com/cli/latest/reference/route53resolver/get-resolver-dnssec-config.html)
- [ICANN — DNSSEC Validation Testing](https://www.icann.org/dns-resolvers-checking-current-trust-anchors)