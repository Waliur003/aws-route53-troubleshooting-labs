# Lab 09 — Route 53 Resolver Rules Misconfiguration

## Overview

This lab demonstrates how to troubleshoot DNS resolution failures caused by a missing Amazon Route 53 Resolver forwarding rule association.

We create two AWS VPCs to simulate a hybrid DNS environment.

The first VPC represents an application network, while the second represents a corporate network hosting an internal DNS server.

We establish VPC peering between both networks and deploy a Linux DNS server using `dnsmasq`.

The corporate DNS server resolves the internal hostname `app.corp.lab09.test` to the private IP address `10.62.1.100`.

Inside the application VPC, we deploy an EC2 troubleshooting client and configure a Route 53 Resolver outbound endpoint with a conditional forwarding rule.

We intentionally leave the Resolver rule unassociated with the application VPC.

As a result, direct queries to the corporate DNS server succeed, but normal queries through the application VPC's DNS Resolver fail.

We investigate VPC routing, DNS connectivity, Resolver endpoints, forwarding rules, and VPC associations using AWS CLI and Linux.

After identifying the missing association, we associate the forwarding rule with the correct VPC and verify that the internal hostname resolves successfully.

Finally, we delete the Resolver endpoint, forwarding rule, EC2 instances, VPC peering connection, and all temporary AWS resources.

**Troubleshooting workflow:**

Two VPCs → VPC Peering → Corporate DNS Server → Outbound Resolver Endpoint → Forwarding Rule → Missing VPC Association → DNS Failure → Investigation → Rule Association → DNS Recovery → Cleanup

---

## 1. Lab Information

| Item | Configuration |
|---|---|
| Incident ID | INC-R53-009 |
| Difficulty | Advanced |
| AWS Region | `us-east-1` |
| AWS Services | Route 53 Resolver, VPC, EC2, IAM, Systems Manager |
| Local Environment | WSL Ubuntu |
| Operating System | Amazon Linux 2023 |
| EC2 Instance Type | `t3.micro` |
| Application VPC | `10.61.0.0/16` |
| Corporate VPC | `10.62.0.0/16` |
| Application Subnet A1 | `10.61.1.0/24` |
| Application Subnet A2 | `10.61.2.0/24` |
| Corporate Subnet | `10.62.1.0/24` |
| VPC A DNS Resolver | `10.61.0.2` |
| Corporate DNS Server | `10.62.1.10` |
| DNS Software | dnsmasq |
| DNS Domain | `corp.lab09.test` |
| Application Hostname | `app.corp.lab09.test` |
| Expected A Record | `10.62.1.100` |
| DNS Port | UDP/TCP 53 |
| VPC Connectivity | VPC Peering |
| Resolver Endpoint | Outbound |
| Resolver Rule Type | FORWARD |
| Fault Injection | Missing VPC rule association |
| Expected Failure | Internal hostname does not resolve through VPC Resolver |
| Remediation | Associate Resolver rule with VPC |
| Verification | AWS CLI, dig, getent, Resolver APIs |

---

## 2. Production Incident Scenario

### Incident Description

A company operates applications inside AWS and maintains a separate corporate DNS environment.

The application VPC uses AmazonProvidedDNS, while the corporate DNS server hosts records for an internal domain.

The application needs to resolve:

`app.corp.lab09.test`

The expected DNS answer is:

`10.62.1.100`

To support internal name resolution, the company configures a Route 53 Resolver outbound endpoint and a conditional forwarding rule.

The forwarding rule should send DNS queries for `corp.lab09.test` to the corporate DNS server at `10.62.1.10`.

However, an engineer creates the Resolver forwarding rule but forgets to associate it with the application VPC.

The corporate DNS server is working, and direct DNS queries over the VPC peering connection succeed.

Despite this, application workloads cannot resolve the hostname through their normal VPC DNS Resolver.

The Cloud Engineer must investigate the failed resolution path and identify the missing Resolver rule association.

### Incident Symptoms

- Corporate DNS server is running.
- dnsmasq responds correctly to direct DNS queries.
- VPC peering is active.
- Private network routing works.
- Route 53 Resolver outbound endpoint is operational.
- Conditional forwarding rule exists.
- The forwarding rule has the correct target DNS server.
- The rule is not associated with application VPC A.
- Queries through `10.61.0.2` fail.
- Direct queries to `10.62.1.10` succeed.
- DNS resolution recovers after the rule association is created.

### Business Impact

- Internal application hostnames cannot be resolved.
- Applications may fail to connect to internal services.
- Cross-network service discovery becomes unavailable.
- Corporate DNS infrastructure appears unreachable despite functioning correctly.
- Engineers may incorrectly investigate security groups, routing, or application servers.
- DNS configuration mistakes can interrupt hybrid cloud connectivity.

### Objective

Identify and correct a Route 53 Resolver forwarding rule association problem while confirming that the corporate DNS server and underlying VPC networking are operational.

---

## 3. AWS Architecture

### Infrastructure Architecture

```text
                         AWS Region
                          us-east-1
                              |
               --------------------------------
               |                              |
               v                              v
         Application VPC                 Corporate VPC
          10.61.0.0/16                   10.62.0.0/16
               |                              |
               v                              v
       Application Subnets             Corporate Subnet
        10.61.1.0/24                    10.62.1.0/24
        10.61.2.0/24                         |
               |                              v
               v                        EC2 DNS Server
         EC2 DNS Client                  10.62.1.10
               |                              |
               v                              v
          VPC Resolver                      dnsmasq
          10.61.0.2                        Port 53
               |                              |
               v                              v
       Conditional Forward Rule       app.corp.lab09.test
          corp.lab09.test                     |
               |                              v
               v                         10.62.1.100
       Resolver Outbound Endpoint
               |
               v
         VPC Peering Connection
               |
               v
          Corporate DNS Server
```

### Before Remediation

```text
Application EC2
       |
       v
Query app.corp.lab09.test
       |
       v
VPC Resolver 10.61.0.2
       |
       v
Forwarding Rule Not Associated
       |
       v
No Conditional Forwarding
       |
       v
Normal Resolution Path
       |
       v
Internal Record Not Found
       |
       v
DNS Resolution Failure
```

### Direct DNS Query

```text
Application EC2
       |
       v
dig @10.62.1.10
       |
       v
VPC Peering
       |
       v
Corporate DNS Server
       |
       v
dnsmasq
       |
       v
10.62.1.100
```

### After Remediation

```text
Application EC2
       |
       v
VPC Resolver 10.61.0.2
       |
       v
Associated Forwarding Rule
       |
       v
Route 53 Resolver
Outbound Endpoint
       |
       v
VPC Peering
       |
       v
Corporate DNS Server
10.62.1.10:53
       |
       v
A Record Returned
       |
       v
10.62.1.100
```

### Network Configuration

| Component | Configuration |
|---|---|
| Application VPC | `10.61.0.0/16` |
| Corporate VPC | `10.62.0.0/16` |
| VPC Peering | Active |
| Route Table A | Route to `10.62.0.0/16` |
| Route Table B | Route to `10.61.0.0/16` |
| Corporate DNS Server | `10.62.1.10` |
| DNS Transport | UDP/TCP 53 |
| Resolver Outbound Endpoint | Two subnet IPs in different AZs |
| Forwarding Domain | `corp.lab09.test` |
| DNS Answer | `10.62.1.100` |

The address `10.62.1.100` is a demonstration DNS value. No web application is required at that address.

---

## 4. Understanding Route 53 Resolver

### What Is Amazon Route 53 Resolver?

Amazon Route 53 Resolver provides DNS resolution for resources inside AWS VPCs.

It supports DNS resolution for public domains, private hosted zones, and conditional forwarding through Resolver rules.

### What Is AmazonProvidedDNS?

AmazonProvidedDNS is the DNS service available inside AWS VPCs.

For the application VPC:

```text
VPC CIDR: 10.61.0.0/16
DNS Resolver: 10.61.0.2
```

### What Is an Inbound Resolver Endpoint?

An inbound Resolver endpoint allows DNS requests from connected networks to enter the AWS DNS resolution environment.

Common use cases include resolving AWS private DNS names from connected corporate networks.

### What Is an Outbound Resolver Endpoint?

An outbound Resolver endpoint forwards matching DNS queries from AWS VPCs to specified DNS servers on connected networks.

This lab uses an outbound endpoint.

### Inbound vs. Outbound

| Feature | Inbound Endpoint | Outbound Endpoint |
|---|---|---|
| Direction | Connected network to AWS | AWS to connected DNS servers |
| Purpose | Resolve AWS DNS from connected networks | Resolve external/internal corporate DNS from AWS |
| Requires Endpoint IPs | Yes | Yes |
| Works With Resolver Rules | Different resolution direction | FORWARD rules |
| Common Scenario | Corporate to AWS DNS | AWS to corporate DNS |

### What Is a Resolver Forwarding Rule?

A forwarding rule determines where DNS queries for a particular domain should be sent.

Example:

```text
Domain: corp.lab09.test
Rule Type: FORWARD
Target DNS Server: 10.62.1.10
Port: 53
```

### What Is a Resolver Rule Association?

A rule association connects a Resolver forwarding rule to a VPC.

Without the association, that VPC does not use the forwarding rule.

### What Is Conditional DNS Forwarding?

Conditional DNS forwarding directs DNS requests for selected domains to specific DNS servers.

Example:

```text
amazon.com
    |
    v
Normal DNS Resolution


app.corp.lab09.test
    |
    v
Conditional FORWARD Rule
    |
    v
Corporate DNS Server
```

### Does VPC Peering Automatically Configure DNS Forwarding?

No.

VPC peering provides private IP connectivity between VPCs.

Resolver rule configuration and VPC associations are separate requirements.

---

## 5. Prerequisites and Safety

### Requirements

- AWS account
- AWS CLI v2
- WSL Ubuntu
- Bash
- EC2 permissions
- VPC permissions
- Route 53 Resolver permissions
- IAM permissions
- Systems Manager access
- Linux DNS utilities
- Git and GitHub

### Safety Rules

- Use disposable VPCs.
- Do not modify production DNS forwarding rules.
- Do not change production Resolver endpoint associations.
- Use dedicated IAM resources.
- Do not expose the corporate DNS service to the public internet.
- Allow DNS only from the application VPC.
- Do not expose SSH.
- Do not commit credentials.
- Delete the Resolver outbound endpoint when finished.
- Verify both VPCs are removed.

### Cost Considerations

This lab creates a Route 53 Resolver outbound endpoint that uses at least two endpoint IP addresses.

Resolver endpoint charges are separate from EC2 and VPC networking costs.

Other possible charges include EC2 instances, EBS storage, public IPv4 addresses, and DNS query processing.

Delete the Resolver endpoint promptly after completing the exercise.

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

export PROJECT_TAG="Route53-Troubleshooting-Lab09"

export VPC_A_CIDR="10.61.0.0/16"
export VPC_B_CIDR="10.62.0.0/16"

export SUBNET_A1_CIDR="10.61.1.0/24"
export SUBNET_A2_CIDR="10.61.2.0/24"
export SUBNET_B_CIDR="10.62.1.0/24"

export DNS_SERVER_IP="10.62.1.10"
export DNS_DOMAIN="corp.lab09.test"
export DNS_RECORD="app.corp.lab09.test"
export DNS_ANSWER="10.62.1.100"

export EC2_ROLE_NAME="route53-lab09-ssm-role"
export PROFILE_NAME="route53-lab09-ssm-profile"
```

### Step 3 — Verify Variables

```bash
echo "$AWS_REGION"
echo "$VPC_A_CIDR"
echo "$VPC_B_CIDR"
echo "$DNS_DOMAIN"
echo "$DNS_RECORD"
```

Keep the original WSL session open to preserve AWS resource identifiers.

---

## 7. Create Application and Corporate VPCs

### Step 1 — Create Application VPC

```bash
export VPC_A_ID=$(aws ec2 create-vpc \
  --cidr-block "$VPC_A_CIDR" \
  --tag-specifications \
  "ResourceType=vpc,Tags=[{Key=Name,Value=route53-lab09-app-vpc},{Key=Project,Value=$PROJECT_TAG}]" \
  --query 'Vpc.VpcId' \
  --output text \
  --region "$AWS_REGION")

echo "$VPC_A_ID"
```

### Step 2 — Create Corporate VPC

```bash
export VPC_B_ID=$(aws ec2 create-vpc \
  --cidr-block "$VPC_B_CIDR" \
  --tag-specifications \
  "ResourceType=vpc,Tags=[{Key=Name,Value=route53-lab09-corp-vpc},{Key=Project,Value=$PROJECT_TAG}]" \
  --query 'Vpc.VpcId' \
  --output text \
  --region "$AWS_REGION")

echo "$VPC_B_ID"
```

### Step 3 — Enable DNS Attributes

```bash
for VPC in "$VPC_A_ID" "$VPC_B_ID"; do
  aws ec2 modify-vpc-attribute \
    --vpc-id "$VPC" \
    --enable-dns-support \
    --region "$AWS_REGION"

  aws ec2 modify-vpc-attribute \
    --vpc-id "$VPC" \
    --enable-dns-hostnames \
    --region "$AWS_REGION"
done
```

### Step 4 — Select Availability Zones

```bash
aws ec2 describe-instance-type-offerings \
  --location-type availability-zone \
  --filters "Name=instance-type,Values=t3.micro" \
  --query 'InstanceTypeOfferings[].Location' \
  --output table \
  --region "$AWS_REGION"
```

Choose two supported Availability Zones:

```bash
export AZ_A="us-east-1a"
export AZ_B="us-east-1b"
```

### Step 5 — Create Application Subnet A1

```bash
export SUBNET_A1_ID=$(aws ec2 create-subnet \
  --vpc-id "$VPC_A_ID" \
  --cidr-block "$SUBNET_A1_CIDR" \
  --availability-zone "$AZ_A" \
  --tag-specifications \
  "ResourceType=subnet,Tags=[{Key=Name,Value=route53-lab09-app-a1},{Key=Project,Value=$PROJECT_TAG}]" \
  --query 'Subnet.SubnetId' \
  --output text \
  --region "$AWS_REGION")
```

### Step 6 — Create Application Subnet A2

```bash
export SUBNET_A2_ID=$(aws ec2 create-subnet \
  --vpc-id "$VPC_A_ID" \
  --cidr-block "$SUBNET_A2_CIDR" \
  --availability-zone "$AZ_B" \
  --tag-specifications \
  "ResourceType=subnet,Tags=[{Key=Name,Value=route53-lab09-app-a2},{Key=Project,Value=$PROJECT_TAG}]" \
  --query 'Subnet.SubnetId' \
  --output text \
  --region "$AWS_REGION")
```

### Step 7 — Create Corporate Subnet

```bash
export SUBNET_B_ID=$(aws ec2 create-subnet \
  --vpc-id "$VPC_B_ID" \
  --cidr-block "$SUBNET_B_CIDR" \
  --availability-zone "$AZ_A" \
  --tag-specifications \
  "ResourceType=subnet,Tags=[{Key=Name,Value=route53-lab09-corp},{Key=Project,Value=$PROJECT_TAG}]" \
  --query 'Subnet.SubnetId' \
  --output text \
  --region "$AWS_REGION")
```

---

## 8. Configure VPC Internet Access

### Step 1 — Create Internet Gateways

Application VPC:

```bash
export IGW_A_ID=$(aws ec2 create-internet-gateway \
  --query 'InternetGateway.InternetGatewayId' \
  --output text \
  --region "$AWS_REGION")

aws ec2 attach-internet-gateway \
  --internet-gateway-id "$IGW_A_ID" \
  --vpc-id "$VPC_A_ID" \
  --region "$AWS_REGION"
```

Corporate VPC:

```bash
export IGW_B_ID=$(aws ec2 create-internet-gateway \
  --query 'InternetGateway.InternetGatewayId' \
  --output text \
  --region "$AWS_REGION")

aws ec2 attach-internet-gateway \
  --internet-gateway-id "$IGW_B_ID" \
  --vpc-id "$VPC_B_ID" \
  --region "$AWS_REGION"
```

### Step 2 — Create Route Tables

```bash
export RT_A_ID=$(aws ec2 create-route-table \
  --vpc-id "$VPC_A_ID" \
  --query 'RouteTable.RouteTableId' \
  --output text \
  --region "$AWS_REGION")

export RT_B_ID=$(aws ec2 create-route-table \
  --vpc-id "$VPC_B_ID" \
  --query 'RouteTable.RouteTableId' \
  --output text \
  --region "$AWS_REGION")
```

### Step 3 — Add Internet Routes

```bash
aws ec2 create-route \
  --route-table-id "$RT_A_ID" \
  --destination-cidr-block 0.0.0.0/0 \
  --gateway-id "$IGW_A_ID" \
  --region "$AWS_REGION"

aws ec2 create-route \
  --route-table-id "$RT_B_ID" \
  --destination-cidr-block 0.0.0.0/0 \
  --gateway-id "$IGW_B_ID" \
  --region "$AWS_REGION"
```

### Step 4 — Associate Subnets

```bash
export ASSOC_A1=$(aws ec2 associate-route-table \
  --route-table-id "$RT_A_ID" \
  --subnet-id "$SUBNET_A1_ID" \
  --query AssociationId \
  --output text \
  --region "$AWS_REGION")

export ASSOC_A2=$(aws ec2 associate-route-table \
  --route-table-id "$RT_A_ID" \
  --subnet-id "$SUBNET_A2_ID" \
  --query AssociationId \
  --output text \
  --region "$AWS_REGION")

export ASSOC_B=$(aws ec2 associate-route-table \
  --route-table-id "$RT_B_ID" \
  --subnet-id "$SUBNET_B_ID" \
  --query AssociationId \
  --output text \
  --region "$AWS_REGION")
```

---

## 9. Establish VPC Peering

### Step 1 — Create Peering Connection

```bash
export PEERING_ID=$(aws ec2 create-vpc-peering-connection \
  --vpc-id "$VPC_A_ID" \
  --peer-vpc-id "$VPC_B_ID" \
  --query 'VpcPeeringConnection.VpcPeeringConnectionId' \
  --output text \
  --region "$AWS_REGION")

echo "$PEERING_ID"
```

### Step 2 — Accept Connection

```bash
aws ec2 accept-vpc-peering-connection \
  --vpc-peering-connection-id "$PEERING_ID" \
  --region "$AWS_REGION"
```

### Step 3 — Create Application-to-Corporate Route

```bash
aws ec2 create-route \
  --route-table-id "$RT_A_ID" \
  --destination-cidr-block "$VPC_B_CIDR" \
  --vpc-peering-connection-id "$PEERING_ID" \
  --region "$AWS_REGION"
```

### Step 4 — Create Corporate-to-Application Route

```bash
aws ec2 create-route \
  --route-table-id "$RT_B_ID" \
  --destination-cidr-block "$VPC_A_CIDR" \
  --vpc-peering-connection-id "$PEERING_ID" \
  --region "$AWS_REGION"
```

### Step 5 — Verify Routing

```bash
aws ec2 describe-route-tables \
  --route-table-ids "$RT_A_ID" "$RT_B_ID" \
  --query 'RouteTables[].{ID:RouteTableId,Routes:Routes}' \
  --output json \
  --region "$AWS_REGION"
```

Expected:

| Route Table | Destination | Next Hop |
|---|---|---|
| Application | `10.62.0.0/16` | VPC Peering |
| Corporate | `10.61.0.0/16` | VPC Peering |

---

## 10. Configure Security Groups

### Step 1 — Create Corporate DNS Security Group

```bash
export DNS_SG_ID=$(aws ec2 create-security-group \
  --group-name route53-lab09-dns-sg \
  --description "Corporate DNS access from application VPC" \
  --vpc-id "$VPC_B_ID" \
  --query GroupId \
  --output text \
  --region "$AWS_REGION")
```

### Step 2 — Allow UDP DNS

```bash
aws ec2 authorize-security-group-ingress \
  --group-id "$DNS_SG_ID" \
  --protocol udp \
  --port 53 \
  --cidr "$VPC_A_CIDR" \
  --region "$AWS_REGION"
```

### Step 3 — Allow TCP DNS

```bash
aws ec2 authorize-security-group-ingress \
  --group-id "$DNS_SG_ID" \
  --protocol tcp \
  --port 53 \
  --cidr "$VPC_A_CIDR" \
  --region "$AWS_REGION"
```

### Step 4 — Create Application Client Security Group

```bash
export CLIENT_SG_ID=$(aws ec2 create-security-group \
  --group-name route53-lab09-client-sg \
  --description "Application DNS troubleshooting client" \
  --vpc-id "$VPC_A_ID" \
  --query GroupId \
  --output text \
  --region "$AWS_REGION")
```

### Step 5 — Create Resolver Endpoint Security Group

```bash
export RESOLVER_SG_ID=$(aws ec2 create-security-group \
  --group-name route53-lab09-resolver-sg \
  --description "Route53 Resolver outbound endpoint" \
  --vpc-id "$VPC_A_ID" \
  --query GroupId \
  --output text \
  --region "$AWS_REGION")
```

### Step 6 — Remove Default IPv4 Allow-All Egress

```bash
aws ec2 revoke-security-group-egress \
  --group-id "$RESOLVER_SG_ID" \
  --protocol -1 \
  --cidr 0.0.0.0/0 \
  --region "$AWS_REGION"
```

### Step 7 — Allow Outbound UDP DNS

```bash
aws ec2 authorize-security-group-egress \
  --group-id "$RESOLVER_SG_ID" \
  --protocol udp \
  --port 53 \
  --cidr "${DNS_SERVER_IP}/32" \
  --region "$AWS_REGION"
```

### Step 8 — Allow Outbound TCP DNS

```bash
aws ec2 authorize-security-group-egress \
  --group-id "$RESOLVER_SG_ID" \
  --protocol tcp \
  --port 53 \
  --cidr "${DNS_SERVER_IP}/32" \
  --region "$AWS_REGION"
```

### Security Group Summary

| Security Group | Rule |
|---|---|
| Corporate DNS | Inbound UDP 53 from VPC A |
| Corporate DNS | Inbound TCP 53 from VPC A |
| Application Client | No inbound SSH |
| Outbound Resolver Endpoint | UDP 53 to `10.62.1.10/32` |
| Outbound Resolver Endpoint | TCP 53 to `10.62.1.10/32` |

Security groups are stateful, so response traffic to permitted requests is automatically allowed.

---

## 11. Deploy Corporate DNS Server

### Step 1 — Create IAM Trust Policy

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

### Step 2 — Create IAM Role

```bash
aws iam create-role \
  --role-name "$EC2_ROLE_NAME" \
  --assume-role-policy-document file://ec2-trust-policy.json \
  --tags Key=Project,Value="$PROJECT_TAG"

aws iam attach-role-policy \
  --role-name "$EC2_ROLE_NAME" \
  --policy-arn arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore
```

### Step 3 — Create Instance Profile

```bash
aws iam create-instance-profile \
  --instance-profile-name "$PROFILE_NAME" \
  --tags Key=Project,Value="$PROJECT_TAG"

aws iam add-role-to-instance-profile \
  --instance-profile-name "$PROFILE_NAME" \
  --role-name "$EC2_ROLE_NAME"
```

### Step 4 — Create DNS Server User Data

Save as `dns-server-user-data.sh`:

```bash
#!/bin/bash
set -euxo pipefail

dnf install -y dnsmasq bind-utils

mkdir -p /etc/route53-lab09

cat > /etc/route53-lab09/dnsmasq.conf <<'CONF'
port=53
listen-address=10.62.1.10
bind-interfaces

no-resolv
no-hosts

local=/corp.lab09.test/
host-record=app.corp.lab09.test,10.62.1.100,30

log-queries
CONF

cat > /etc/systemd/system/route53-lab09-dns.service <<'SERVICE'
[Unit]
Description=Route 53 Lab09 Corporate DNS
After=network-online.target
Wants=network-online.target

[Service]
Type=forking
PIDFile=/run/route53-lab09-dns.pid
ExecStart=/usr/sbin/dnsmasq --conf-file=/etc/route53-lab09/dnsmasq.conf --pid-file=/run/route53-lab09-dns.pid
ExecStop=/bin/kill -TERM $MAINPID
Restart=on-failure

[Install]
WantedBy=multi-user.target
SERVICE

systemctl daemon-reload
systemctl enable --now route53-lab09-dns.service
```

### Step 5 — Retrieve Amazon Linux AMI

```bash
export AMI_ID=$(aws ssm get-parameter \
  --name "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64" \
  --query Parameter.Value \
  --output text \
  --region "$AWS_REGION")
```

### Step 6 — Launch Corporate DNS Server

```bash
export DNS_INSTANCE_ID=$(aws ec2 run-instances \
  --image-id "$AMI_ID" \
  --instance-type t3.micro \
  --subnet-id "$SUBNET_B_ID" \
  --private-ip-address "$DNS_SERVER_IP" \
  --security-group-ids "$DNS_SG_ID" \
  --associate-public-ip-address \
  --iam-instance-profile "Name=$PROFILE_NAME" \
  --user-data file://dns-server-user-data.sh \
  --metadata-options "HttpTokens=required,HttpEndpoint=enabled" \
  --tag-specifications \
  "ResourceType=instance,Tags=[{Key=Name,Value=route53-lab09-corporate-dns},{Key=Project,Value=$PROJECT_TAG}]" \
  --query 'Instances[0].InstanceId' \
  --output text \
  --region "$AWS_REGION")

echo "$DNS_INSTANCE_ID"
```

### Step 7 — Wait for EC2

```bash
aws ec2 wait instance-running \
  --instance-ids "$DNS_INSTANCE_ID" \
  --region "$AWS_REGION"

aws ec2 wait instance-status-ok \
  --instance-ids "$DNS_INSTANCE_ID" \
  --region "$AWS_REGION"
```

### Step 8 — Connect Using Systems Manager

```bash
aws ssm start-session \
  --target "$DNS_INSTANCE_ID" \
  --region "$AWS_REGION"
```

### Step 9 — Verify DNS Service

Inside EC2:

```bash
sudo systemctl status route53-lab09-dns --no-pager
```

Verify listening port:

```bash
sudo ss -lunpt | grep ':53 '
```

### Step 10 — Test UDP DNS

```bash
dig @10.62.1.10 app.corp.lab09.test A
```

Expected:

```text
status: NOERROR

app.corp.lab09.test. 30 IN A 10.62.1.100
```

### Step 11 — Test TCP DNS

```bash
dig +tcp @10.62.1.10 app.corp.lab09.test A
```

Expected: same A record.

### Step 12 — Troubleshoot Service If Needed

```bash
sudo journalctl \
  -u route53-lab09-dns \
  -n 50 \
  --no-pager
```

Exit:

```bash
exit
```

---

## 12. Deploy Application DNS Client

### Step 1 — Launch Client EC2

```bash
export CLIENT_INSTANCE_ID=$(aws ec2 run-instances \
  --image-id "$AMI_ID" \
  --instance-type t3.micro \
  --subnet-id "$SUBNET_A1_ID" \
  --security-group-ids "$CLIENT_SG_ID" \
  --associate-public-ip-address \
  --iam-instance-profile "Name=$PROFILE_NAME" \
  --metadata-options "HttpTokens=required,HttpEndpoint=enabled" \
  --tag-specifications \
  "ResourceType=instance,Tags=[{Key=Name,Value=route53-lab09-dns-client},{Key=Project,Value=$PROJECT_TAG}]" \
  --query 'Instances[0].InstanceId' \
  --output text \
  --region "$AWS_REGION")
```

### Step 2 — Wait for Client

```bash
aws ec2 wait instance-running \
  --instance-ids "$CLIENT_INSTANCE_ID" \
  --region "$AWS_REGION"

aws ec2 wait instance-status-ok \
  --instance-ids "$CLIENT_INSTANCE_ID" \
  --region "$AWS_REGION"
```

### Step 3 — Connect to Client

```bash
aws ssm start-session \
  --target "$CLIENT_INSTANCE_ID" \
  --region "$AWS_REGION"
```

Install DNS utilities:

```bash
sudo dnf install -y bind-utils
```

### Step 4 — Configure Client Variables

```bash
export DNS_SERVER_IP="10.62.1.10"
export DNS_RECORD="app.corp.lab09.test"
export VPC_RESOLVER="10.61.0.2"
```

### Step 5 — Test Direct DNS over Peering

```bash
dig @"$DNS_SERVER_IP" "$DNS_RECORD" A
```

Expected:

```text
10.62.1.100
```

### Step 6 — Test TCP DNS

```bash
dig +tcp @"$DNS_SERVER_IP" "$DNS_RECORD" A
```

Expected: successful resolution.

### Step 7 — Test VPC Resolver

```bash
dig @"$VPC_RESOLVER" "$DNS_RECORD" A
```

Expected before conditional forwarding is associated: the internal hostname is not resolved.

Often the result is:

```text
status: NXDOMAIN
```

This demonstrates that direct network access to the corporate DNS server does not automatically configure DNS forwarding.

Exit:

```bash
exit
```

---

## 13. Create Outbound Resolver Endpoint

### Step 1 — Create Resolver Endpoint

```bash
export ENDPOINT_ID=$(aws route53resolver create-resolver-endpoint \
  --creator-request-id "route53-lab09-endpoint-$(date +%s)" \
  --name "route53-lab09-outbound" \
  --security-group-ids "$RESOLVER_SG_ID" \
  --direction OUTBOUND \
  --ip-addresses \
    "SubnetId=$SUBNET_A1_ID" \
    "SubnetId=$SUBNET_A2_ID" \
  --tags Key=Project,Value="$PROJECT_TAG" \
  --query 'ResolverEndpoint.Id' \
  --output text \
  --region "$AWS_REGION")

echo "$ENDPOINT_ID"
```

### Step 2 — Verify Endpoint

```bash
aws route53resolver get-resolver-endpoint \
  --resolver-endpoint-id "$ENDPOINT_ID" \
  --query 'ResolverEndpoint.{ID:Id,Name:Name,Direction:Direction,Status:Status}' \
  --output table \
  --region "$AWS_REGION"
```

Expected after endpoint creation completes:

```text
Status: OPERATIONAL
```

### Step 3 — Inspect Endpoint IPs

```bash
aws route53resolver list-resolver-endpoint-ip-addresses \
  --resolver-endpoint-id "$ENDPOINT_ID" \
  --output table \
  --region "$AWS_REGION"
```

The endpoint IP addresses are used by Route 53 Resolver when forwarding DNS queries.

The EC2 DNS client should continue using the VPC Resolver rather than querying the outbound endpoint directly.

---

## 14. Fault Injection — Missing Resolver Rule Association

### Step 1 — Create Conditional Forwarding Rule

```bash
export RULE_ID=$(aws route53resolver create-resolver-rule \
  --creator-request-id "route53-lab09-rule-$(date +%s)" \
  --name "route53-lab09-corporate-forward" \
  --rule-type FORWARD \
  --domain-name "$DNS_DOMAIN" \
  --resolver-endpoint-id "$ENDPOINT_ID" \
  --target-ips "Ip=$DNS_SERVER_IP,Port=53" \
  --tags Key=Project,Value="$PROJECT_TAG" \
  --query 'ResolverRule.Id' \
  --output text \
  --region "$AWS_REGION")

echo "$RULE_ID"
```

### Step 2 — Verify Forwarding Rule

```bash
aws route53resolver get-resolver-rule \
  --resolver-rule-id "$RULE_ID" \
  --query 'ResolverRule.{ID:Id,Domain:DomainName,Type:RuleType,Endpoint:ResolverEndpointId,TargetIPs:TargetIps,Status:Status}' \
  --output json \
  --region "$AWS_REGION"
```

Expected:

```text
DomainName: corp.lab09.test
RuleType: FORWARD
TargetIp: 10.62.1.10
Port: 53
```

Wait for the rule to reach `COMPLETE`.

### Step 3 — Intentionally Skip the Association

Do not run `associate-resolver-rule` yet.

The forwarding rule exists, but no application VPC is using it.

### Step 4 — Inspect Rule Associations

```bash
aws route53resolver list-resolver-rule-associations \
  --filters "Name=ResolverRuleId,Values=$RULE_ID" \
  --query 'ResolverRuleAssociations[].{VPC:VPCId,Status:Status}' \
  --output table \
  --region "$AWS_REGION"
```

Expected: no association with application VPC A.

### Fault Injection Summary

| Component | Expected State |
|---|---|
| Corporate DNS Server | Healthy |
| VPC Peering | Active |
| Outbound Endpoint | OPERATIONAL |
| Forwarding Rule | Exists |
| Rule Type | FORWARD |
| Domain | `corp.lab09.test` |
| Target Server | `10.62.1.10` |
| VPC Association | Missing |
| Expected DNS Result | Failure through VPC Resolver |

---

## 15. Reproduce and Investigate DNS Failure

### Step 1 — Connect to Application Client

```bash
aws ssm start-session \
  --target "$CLIENT_INSTANCE_ID" \
  --region "$AWS_REGION"
```

Inside EC2:

```bash
export DNS_SERVER_IP="10.62.1.10"
export DNS_RECORD="app.corp.lab09.test"
export VPC_RESOLVER="10.61.0.2"
```

### Step 2 — Verify Direct DNS

```bash
dig @"$DNS_SERVER_IP" "$DNS_RECORD" A
```

Expected: `10.62.1.100`.

### Step 3 — Query VPC Resolver

```bash
dig @"$VPC_RESOLVER" "$DNS_RECORD" A
```

Expected: no successful resolution for the corporate hostname.

### Step 4 — Verify Short Output

```bash
dig +short @"$VPC_RESOLVER" "$DNS_RECORD" A
```

Expected: no A record.

### Step 5 — Test Linux Resolution

```bash
getent ahostsv4 "$DNS_RECORD"
```

Expected: no address, assuming the system uses AmazonProvidedDNS.

### Step 6 — Inspect System Resolver

```bash
cat /etc/resolv.conf
```

Confirm that the client uses the normal VPC DNS resolution path.

### Step 7 — Save DNS Evidence

```bash
dig @"$DNS_SERVER_IP" "$DNS_RECORD" A \
  > "$HOME/lab09-direct-dns-before.txt"

dig @"$VPC_RESOLVER" "$DNS_RECORD" A \
  > "$HOME/lab09-vpc-dns-before.txt"
```

Exit:

```bash
exit
```

### Step 8 — Inspect Resolver Endpoint

From WSL:

```bash
aws route53resolver get-resolver-endpoint \
  --resolver-endpoint-id "$ENDPOINT_ID" \
  --output json \
  --region "$AWS_REGION"
```

Expected: `OPERATIONAL`.

### Step 9 — Inspect Forwarding Rule

```bash
aws route53resolver get-resolver-rule \
  --resolver-rule-id "$RULE_ID" \
  --output json \
  --region "$AWS_REGION"
```

Expected: correct domain, endpoint, and target IP.

### Step 10 — Inspect Associations

```bash
aws route53resolver list-resolver-rule-associations \
  --filters "Name=ResolverRuleId,Values=$RULE_ID" \
  --output json \
  --region "$AWS_REGION"
```

Expected: missing application VPC association.

### Step 11 — Verify VPC DNS Settings

```bash
aws ec2 describe-vpc-attribute \
  --vpc-id "$VPC_A_ID" \
  --attribute enableDnsSupport \
  --region "$AWS_REGION"

aws ec2 describe-vpc-attribute \
  --vpc-id "$VPC_A_ID" \
  --attribute enableDnsHostnames \
  --region "$AWS_REGION"
```

Expected: enabled.

### Step 12 — Verify Network Routes

```bash
aws ec2 describe-route-tables \
  --route-table-ids "$RT_A_ID" "$RT_B_ID" \
  --query 'RouteTables[].{ID:RouteTableId,Routes:Routes}' \
  --output json \
  --region "$AWS_REGION"
```

### Step 13 — Inspect DNS Security Group

```bash
aws ec2 describe-security-groups \
  --group-ids "$DNS_SG_ID" \
  --query 'SecurityGroups[0].IpPermissions' \
  --output json \
  --region "$AWS_REGION"
```

### Step 14 — Save Configuration Evidence

```bash
aws route53resolver get-resolver-rule \
  --resolver-rule-id "$RULE_ID" \
  --output json \
  --region "$AWS_REGION" \
  > lab09-before-rule.json
```

```bash
aws route53resolver list-resolver-rule-associations \
  --filters "Name=ResolverRuleId,Values=$RULE_ID" \
  --output json \
  --region "$AWS_REGION" \
  > lab09-before-associations.json
```

### Investigation Matrix

| Investigation | Expected Finding |
|---|---|
| Corporate DNS | Healthy |
| Direct DNS | Successful |
| VPC Peering | Working |
| Security Groups | Correct |
| Outbound Endpoint | OPERATIONAL |
| Forwarding Rule | Exists |
| Rule Domain | Correct |
| Target DNS Server | Correct |
| VPC Association | Missing |
| VPC DNS Query | Failed |
| Root Cause | Missing forwarding rule association |

---

## 16. Root Cause Analysis

### Root Cause

The Route 53 Resolver forwarding rule for `corp.lab09.test` was created but not associated with the application VPC.

The outbound Resolver endpoint and corporate DNS server were operational.

The target DNS server was reachable over the VPC peering connection, and direct DNS queries succeeded.

However, the VPC Resolver did not apply the forwarding rule because the application VPC had no association with that rule.

As a result, normal DNS queries for the corporate hostname followed the default resolution path and could not locate the internal record.

### Root Cause Flow

```text
EC2 Application Client
        |
        v
VPC DNS Resolver
        |
        v
Check Applicable Rules
        |
        v
No Associated Corporate Forward Rule
        |
        v
Normal DNS Resolution Path
        |
        v
Corporate Record Unavailable
        |
        v
DNS Failure
```

### Five Whys

1. **Why did the corporate hostname fail?** The VPC Resolver could not return the corporate DNS record.
2. **Why wasn't the corporate DNS server queried through the forwarding path?** The forwarding rule was not active for the application VPC.
3. **Why wasn't the forwarding rule active?** Its VPC association was missing.
4. **Why did direct DNS queries work?** Network routing and the corporate DNS server were functioning properly.
5. **How was the incident resolved?** The forwarding rule was associated with application VPC A.

### Root Cause Summary

| Component | Finding |
|---|---|
| AWS Service | Route 53 Resolver |
| Incident | Resolver Rules Misconfiguration |
| Corporate DNS Server | Healthy |
| VPC Peering | Working |
| Resolver Endpoint | Operational |
| Forwarding Rule | Correct |
| Rule Association | Missing |
| Root Cause | No association with application VPC |
| Remediation | Associate forwarding rule |
| DNS Server Redeployment | Not required |

---

## 17. Remediation and Final Verification

### Step 1 — Associate Forwarding Rule

From WSL:

```bash
export RULE_ASSOC_ID=$(aws route53resolver associate-resolver-rule \
  --resolver-rule-id "$RULE_ID" \
  --vpc-id "$VPC_A_ID" \
  --name "route53-lab09-app-association" \
  --query 'ResolverRuleAssociation.Id' \
  --output text \
  --region "$AWS_REGION")

echo "$RULE_ASSOC_ID"
```

### Step 2 — Verify Association

```bash
aws route53resolver get-resolver-rule-association \
  --resolver-rule-association-id "$RULE_ASSOC_ID" \
  --query 'ResolverRuleAssociation.{VPC:VPCId,Rule:ResolverRuleId,Status:Status}' \
  --output table \
  --region "$AWS_REGION"
```

Wait until the association status is:

```text
COMPLETE
```

### Step 3 — Verify Forwarding Rule

```bash
aws route53resolver get-resolver-rule \
  --resolver-rule-id "$RULE_ID" \
  --query 'ResolverRule.{Domain:DomainName,Type:RuleType,Status:Status,Targets:TargetIps}' \
  --output json \
  --region "$AWS_REGION"
```

### Step 4 — Connect to Application EC2

```bash
aws ssm start-session \
  --target "$CLIENT_INSTANCE_ID" \
  --region "$AWS_REGION"
```

Inside EC2:

```bash
export DNS_RECORD="app.corp.lab09.test"
export VPC_RESOLVER="10.61.0.2"
```

### Step 5 — Verify VPC DNS Resolution

```bash
dig @"$VPC_RESOLVER" "$DNS_RECORD" A
```

Expected after the association takes effect and any cached negative answer expires:

```text
status: NOERROR

app.corp.lab09.test. 30 IN A 10.62.1.100
```

### Step 6 — Verify Short Output

```bash
dig +short @"$VPC_RESOLVER" "$DNS_RECORD" A
```

Expected:

```text
10.62.1.100
```

### Step 7 — Verify Linux Resolver

```bash
getent ahostsv4 "$DNS_RECORD"
```

Expected: `10.62.1.100`.

### Step 8 — Test TCP DNS

```bash
dig +tcp @"$VPC_RESOLVER" "$DNS_RECORD" A
```

Expected: successful DNS resolution.

### Step 9 — Save Recovery Evidence

```bash
dig @"$VPC_RESOLVER" "$DNS_RECORD" A \
  > "$HOME/lab09-vpc-dns-after.txt"
```

Exit:

```bash
exit
```

### Step 10 — Save Corrected Association

```bash
aws route53resolver get-resolver-rule-association \
  --resolver-rule-association-id "$RULE_ASSOC_ID" \
  --output json \
  --region "$AWS_REGION" \
  > lab09-after-association.json
```

### Before and After Comparison

| Investigation | Before Fix | After Fix |
|---|---|---|
| Corporate DNS | Healthy | Healthy |
| Peering | Working | Working |
| Outbound Endpoint | OPERATIONAL | OPERATIONAL |
| Forwarding Rule | Exists | Exists |
| Rule Association | Missing | COMPLETE |
| Direct DNS | Successful | Successful |
| VPC Resolver DNS | Failed | Successful |
| Returned A Record | None | 10.62.1.100 |
| Incident | Active | Resolved |

### Final Verification Criteria

The lab is successful when the forwarding rule is associated with the application VPC, the association is `COMPLETE`, and DNS queries through the VPC Resolver return the expected corporate A record.

If the query still fails immediately after association, check for cached negative DNS responses and verify the association has finished propagating.

---

## 18. AWS Resource Cleanup

**Warning:** Delete only resources created for this lab. Route 53 Resolver outbound endpoint charges can continue while the endpoint remains provisioned.

### Step 1 — Disassociate Resolver Rule

```bash
aws route53resolver disassociate-resolver-rule \
  --resolver-rule-id "$RULE_ID" \
  --vpc-id "$VPC_A_ID" \
  --region "$AWS_REGION"
```

Verify:

```bash
aws route53resolver list-resolver-rule-associations \
  --filters "Name=ResolverRuleId,Values=$RULE_ID" \
  --output table \
  --region "$AWS_REGION"
```

Wait until the association is deleted.

### Step 2 — Delete Forwarding Rule

```bash
aws route53resolver delete-resolver-rule \
  --resolver-rule-id "$RULE_ID" \
  --region "$AWS_REGION"
```

Verify:

```bash
aws route53resolver list-resolver-rules \
  --query "ResolverRules[?Id=='${RULE_ID}']" \
  --output json \
  --region "$AWS_REGION"
```

Wait until the rule is removed.

### Step 3 — Delete Outbound Resolver Endpoint

```bash
aws route53resolver delete-resolver-endpoint \
  --resolver-endpoint-id "$ENDPOINT_ID" \
  --region "$AWS_REGION"
```

Verify:

```bash
aws route53resolver list-resolver-endpoints \
  --query "ResolverEndpoints[?Id=='${ENDPOINT_ID}'].{ID:Id,Status:Status}" \
  --output table \
  --region "$AWS_REGION"
```

Wait until the endpoint is deleted and its network interfaces disappear.

### Step 4 — Verify EC2 Root Volumes

```bash
aws ec2 describe-instances \
  --instance-ids "$DNS_INSTANCE_ID" "$CLIENT_INSTANCE_ID" \
  --query 'Reservations[].Instances[].{ID:InstanceId,Volumes:BlockDeviceMappings}' \
  --output json \
  --region "$AWS_REGION"
```

Verify `DeleteOnTermination=true` for each root EBS volume.

### Step 5 — Terminate Both EC2 Instances

```bash
aws ec2 terminate-instances \
  --instance-ids "$DNS_INSTANCE_ID" "$CLIENT_INSTANCE_ID" \
  --region "$AWS_REGION"

aws ec2 wait instance-terminated \
  --instance-ids "$DNS_INSTANCE_ID" "$CLIENT_INSTANCE_ID" \
  --region "$AWS_REGION"
```

### Step 6 — Verify IAM Role Ownership

```bash
aws iam list-role-tags \
  --role-name "$EC2_ROLE_NAME"
```

Confirm the Lab 09 project tag.

### Step 7 — Delete IAM Resources

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

### Step 8 — Verify Network Interfaces

```bash
for VPC in "$VPC_A_ID" "$VPC_B_ID"; do
  aws ec2 describe-network-interfaces \
    --filters "Name=vpc-id,Values=$VPC" \
    --query 'NetworkInterfaces[].{ID:NetworkInterfaceId,Status:Status,Description:Description}' \
    --output table \
    --region "$AWS_REGION"
done
```

Ensure the EC2 and Resolver endpoint network interfaces have been removed.

### Step 9 — Delete Security Groups

```bash
aws ec2 delete-security-group \
  --group-id "$CLIENT_SG_ID" \
  --region "$AWS_REGION"

aws ec2 delete-security-group \
  --group-id "$RESOLVER_SG_ID" \
  --region "$AWS_REGION"

aws ec2 delete-security-group \
  --group-id "$DNS_SG_ID" \
  --region "$AWS_REGION"
```

### Step 10 — Remove Peering Routes

```bash
aws ec2 delete-route \
  --route-table-id "$RT_A_ID" \
  --destination-cidr-block "$VPC_B_CIDR" \
  --region "$AWS_REGION"

aws ec2 delete-route \
  --route-table-id "$RT_B_ID" \
  --destination-cidr-block "$VPC_A_CIDR" \
  --region "$AWS_REGION"
```

### Step 11 — Delete Peering Connection

```bash
aws ec2 delete-vpc-peering-connection \
  --vpc-peering-connection-id "$PEERING_ID" \
  --region "$AWS_REGION"
```

### Step 12 — Disassociate Route Tables

```bash
aws ec2 disassociate-route-table \
  --association-id "$ASSOC_A1" \
  --region "$AWS_REGION"

aws ec2 disassociate-route-table \
  --association-id "$ASSOC_A2" \
  --region "$AWS_REGION"

aws ec2 disassociate-route-table \
  --association-id "$ASSOC_B" \
  --region "$AWS_REGION"
```

### Step 13 — Delete Route Tables

```bash
aws ec2 delete-route-table \
  --route-table-id "$RT_A_ID" \
  --region "$AWS_REGION"

aws ec2 delete-route-table \
  --route-table-id "$RT_B_ID" \
  --region "$AWS_REGION"
```

### Step 14 — Delete Subnets

```bash
aws ec2 delete-subnet \
  --subnet-id "$SUBNET_A1_ID" \
  --region "$AWS_REGION"

aws ec2 delete-subnet \
  --subnet-id "$SUBNET_A2_ID" \
  --region "$AWS_REGION"

aws ec2 delete-subnet \
  --subnet-id "$SUBNET_B_ID" \
  --region "$AWS_REGION"
```

### Step 15 — Delete Internet Gateways

```bash
aws ec2 detach-internet-gateway \
  --internet-gateway-id "$IGW_A_ID" \
  --vpc-id "$VPC_A_ID" \
  --region "$AWS_REGION"

aws ec2 delete-internet-gateway \
  --internet-gateway-id "$IGW_A_ID" \
  --region "$AWS_REGION"

aws ec2 detach-internet-gateway \
  --internet-gateway-id "$IGW_B_ID" \
  --vpc-id "$VPC_B_ID" \
  --region "$AWS_REGION"

aws ec2 delete-internet-gateway \
  --internet-gateway-id "$IGW_B_ID" \
  --region "$AWS_REGION"
```

### Step 16 — Delete Both VPCs

```bash
aws ec2 delete-vpc \
  --vpc-id "$VPC_A_ID" \
  --region "$AWS_REGION"

aws ec2 delete-vpc \
  --vpc-id "$VPC_B_ID" \
  --region "$AWS_REGION"
```

### Step 17 — Verify Resolver Cleanup

```bash
aws route53resolver list-resolver-endpoints \
  --query "ResolverEndpoints[?Id=='${ENDPOINT_ID}']" \
  --output json \
  --region "$AWS_REGION"
```

Expected:

```json
[]
```

Verify the rule:

```bash
aws route53resolver list-resolver-rules \
  --query "ResolverRules[?Id=='${RULE_ID}']" \
  --output json \
  --region "$AWS_REGION"
```

Expected: empty array.

### Step 18 — Verify VPC Cleanup

```bash
aws ec2 describe-vpcs \
  --vpc-ids "$VPC_A_ID" "$VPC_B_ID" \
  --region "$AWS_REGION"
```

Expected: not-found error after deletion.

Also verify EC2 termination, EBS volume deletion, IAM cleanup, and peering connection removal.

### Cleanup Summary

| Resource | Expected Result |
|---|---|
| Resolver Rule Association | Deleted |
| Forwarding Rule | Deleted |
| Outbound Resolver Endpoint | Deleted |
| Resolver Endpoint ENIs | Deleted |
| Corporate DNS EC2 | Terminated |
| Application Client EC2 | Terminated |
| Root EBS Volumes | Deleted |
| IAM Role | Deleted |
| Instance Profile | Deleted |
| Security Groups | Deleted |
| VPC Peering | Deleted |
| Route Tables | Deleted |
| Subnets | Deleted |
| Internet Gateways | Deleted |
| Application VPC | Deleted |
| Corporate VPC | Deleted |

---

## 19. Interview Questions and Answers

### Q1. What is Amazon Route 53 Resolver?

An AWS DNS service that resolves DNS queries inside VPCs and supports conditional forwarding through Resolver rules.

### Q2. What is an outbound Resolver endpoint?

A Resolver endpoint that forwards matching DNS queries from AWS VPCs to DNS servers in connected networks.

### Q3. What is an inbound Resolver endpoint?

An endpoint that allows DNS systems from connected networks to query AWS DNS through Route 53 Resolver.

### Q4. What is conditional DNS forwarding?

A DNS configuration that forwards requests for specific domains to designated DNS servers.

### Q5. What is a Route 53 Resolver forwarding rule?

A rule specifying a domain and the target DNS servers used for matching DNS queries.

### Q6. Why did DNS resolution fail in this lab?

The forwarding rule existed, but it was not associated with the application VPC.

### Q7. Why did direct dig work?

Direct `dig` queried the corporate DNS server without depending on the VPC Resolver forwarding rule.

### Q8. Does VPC peering automatically enable conditional DNS forwarding?

No. VPC peering provides private connectivity but does not automatically configure Resolver forwarding rules or associations.

### Q9. How do you inspect Resolver rule associations?

```bash
aws route53resolver list-resolver-rule-associations \
  --region us-east-1
```

### Q10. How do you associate a forwarding rule with a VPC?

```bash
aws route53resolver associate-resolver-rule \
  --resolver-rule-id YOUR_RULE_ID \
  --vpc-id YOUR_VPC_ID \
  --region us-east-1
```

### Q11. What would you investigate if forwarding still failed after association?

I would check the association status, rule domain, outbound endpoint status, target DNS server, security groups, network ACLs, VPC routing, and DNS responses from the target server.

### Q12. How would you explain this lab in an interview?

I created two peered AWS VPCs to simulate an application network and a corporate DNS environment.

I deployed a dnsmasq server in the corporate VPC and configured an A record for an internal application hostname.

I created a Route 53 Resolver outbound endpoint and a conditional forwarding rule, but intentionally left the rule unassociated with the application VPC.

Direct DNS queries to the corporate server succeeded, while queries through the application VPC Resolver failed.

I investigated VPC peering, routing, security groups, Resolver endpoint status, forwarding rules, and VPC associations.

I identified the missing rule association as the root cause and corrected it using AWS CLI.

After remediation, the internal hostname resolved successfully through the VPC Resolver.

Finally, I removed the Resolver endpoint and all temporary AWS resources.

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
└── 09-resolver-rules-misconfiguration/
    ├── README.md
    ├── ec2-trust-policy.json
    ├── dns-server-user-data.sh
    ├── lab09-before-rule.json
    ├── lab09-before-associations.json
    └── lab09-after-association.json
```

### File Descriptions

| File | Purpose |
|---|---|
| `README.md` | Complete troubleshooting documentation |
| `ec2-trust-policy.json` | IAM trust policy for EC2 |
| `dns-server-user-data.sh` | Configures the dnsmasq corporate DNS server |
| `lab09-before-rule.json` | Records the forwarding rule before remediation |
| `lab09-before-associations.json` | Captures the missing rule association |
| `lab09-after-association.json` | Captures the corrected VPC association |

### Optional DNS Evidence

You can also preserve:

```text
lab09-direct-dns-before.txt
lab09-vpc-dns-before.txt
lab09-vpc-dns-after.txt
```

These files demonstrate the difference between direct corporate DNS queries and DNS resolution through the VPC Resolver.

The DNS evidence is initially stored on the EC2 instance. Copy it to your repository before terminating the instance if you want to publish it.

Review all evidence for sensitive information before uploading it to GitHub.

---

## 21. Lessons Learned and Skills Demonstrated

### Lessons Learned

This lab demonstrates how a missing Route 53 Resolver rule association can prevent internal DNS resolution even when the corporate DNS server and network connectivity are functioning correctly.

We created two AWS VPCs and connected them through VPC peering.

We deployed a corporate DNS server using dnsmasq and configured an internal A record.

We verified that the DNS server responded to direct queries from the application VPC.

We then created a Route 53 Resolver outbound endpoint and a conditional forwarding rule.

The forwarding rule was intentionally left unassociated with the application VPC.

As a result, DNS queries through the application VPC Resolver failed even though direct queries to the corporate DNS server succeeded.

We investigated the problem by inspecting Resolver endpoint status, forwarding rule configuration, VPC associations, security groups, and network routes.

After associating the forwarding rule with the application VPC, the internal hostname resolved successfully.

The exercise showed that functional network connectivity and a valid forwarding rule do not guarantee DNS forwarding until the correct VPC association exists.

**Key Lesson:** When direct DNS queries succeed but VPC Resolver queries fail, verify that the matching conditional forwarding rule is associated with the correct VPC.

### Skills Demonstrated

- Amazon Route 53 Resolver
- Outbound Resolver endpoints
- Conditional DNS forwarding
- FORWARD resolver rules
- Resolver rule VPC associations
- AWS VPC DNS
- Hybrid DNS architecture
- VPC peering
- Private network routing
- Linux dnsmasq
- UDP and TCP DNS
- Linux dig
- Linux getent
- Amazon EC2
- AWS Systems Manager
- IAM roles
- Security groups
- AWS CLI v2
- DNS failure investigation
- Root cause analysis
- DNS forwarding remediation
- AWS resource cleanup

### Final Outcome

| Item | Expected Result |
|---|---|
| Incident | INC-R53-009 |
| Scenario | Resolver Rules Misconfiguration |
| Corporate DNS Server | Healthy |
| VPC Peering | Working |
| Resolver Outbound Endpoint | Operational |
| Forwarding Rule | Created |
| Rule Association Before Fix | Missing |
| Direct DNS Query | Successful |
| VPC DNS Before Fix | Failed |
| Root Cause | Missing VPC association |
| Remediation | Associate Resolver rule |
| Association After Fix | COMPLETE |
| VPC DNS After Fix | 10.62.1.100 |
| Cleanup | Temporary resources removed |
| Incident Status | Resolved after verification |

**Key Takeaway:** Route 53 Resolver troubleshooting requires verifying the full DNS forwarding path, including network connectivity, outbound endpoint health, forwarding rule configuration, and VPC associations. A rule that exists but is not associated with the correct VPC cannot provide conditional DNS resolution for that VPC.