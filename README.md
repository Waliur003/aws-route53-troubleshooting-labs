# Amazon Route 53 Troubleshooting Labs

## Overview

This repository contains 10 hands-on Amazon Route 53 troubleshooting labs designed to develop practical Cloud Engineering and Cloud Security Engineering skills.

The labs simulate real-world DNS incidents involving incorrect DNS records, failed hostname resolution, caching problems, public and private hosted zones, alias records, health checks, DNS failover, split-horizon DNS, and Route 53 Resolver forwarding.

Each lab focuses on identifying a problem, investigating its root cause, applying remediation, verifying recovery, and cleaning up temporary AWS resources.

The exercises use AWS CLI, Bash, Linux networking tools, and AWS infrastructure.

### Main Goals

- Learn how Amazon Route 53 works.
- Troubleshoot production-style DNS problems.
- Understand DNS records and DNS resolution.
- Investigate public and private DNS configurations.
- Understand DNS caching and TTL behavior.
- Troubleshoot health checks and DNS failover.
- Investigate hybrid DNS forwarding.
- Improve AWS CLI and Linux troubleshooting skills.
- Practice incident investigation and root cause analysis.
- Build a documented cloud troubleshooting portfolio.

---

## 1. Technologies Used

| Technology | Purpose |
|---|---|
| Amazon Route 53 | DNS hosting and routing |
| Route 53 Resolver | VPC DNS resolution and forwarding |
| Amazon VPC | Private network configuration |
| Amazon EC2 | DNS troubleshooting client |
| AWS CLI v2 | AWS resource management |
| Ubuntu / WSL2 | Local Linux environment |
| Bash | Automation and troubleshooting |
| `dig` | DNS queries and record investigation |
| `nslookup` | Hostname resolution testing |
| `host` | DNS lookup troubleshooting |
| `getent` | Operating system hostname resolution |
| `curl` | HTTP and endpoint connectivity testing |
| `nc` | TCP connectivity verification |
| Amazon CloudWatch | Monitoring and DNS health investigation |
| IAM | Access control |
| Git / GitHub | Documentation and version control |

---

## 2. Repository Structure

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
├── 09-split-horizon-dns-troubleshooting/
│   └── README.md
│
└── 10-route53-resolver-forwarding-problem/
    └── README.md
```

Supporting JSON, Bash, DNS configuration, and other files will be added inside individual lab folders when required.

---

## 3. Troubleshooting Labs

| Lab | Scenario | Main Troubleshooting Focus |
|---|---|---|
| 01 | DNS Record Not Resolving | Missing records, DNS response codes, hosted-zone verification |
| 02 | Wrong A Record | Incorrect IPv4 target and traffic redirection |
| 03 | CNAME Misconfiguration | Incorrect canonical hostname, invalid record configuration |
| 04 | DNS TTL and Caching Problem | Cached DNS responses and delayed propagation |
| 05 | Public vs Private Hosted Zone | VPC associations, DNS visibility, internal resolution |
| 06 | Incorrect Alias Record | Alias target configuration and AWS resource routing |
| 07 | Route 53 Health Check Failure | Incorrect endpoint, health-check configuration, monitoring |
| 08 | DNS Failover Not Working | Primary/secondary records and health check associations |
| 09 | Split-Horizon DNS Troubleshooting | Different internal and external DNS responses |
| 10 | Route 53 Resolver Forwarding Problem | Resolver rules, forwarding targets, endpoint connectivity |

The labs progress from fundamental DNS troubleshooting to more advanced DNS architectures and incident investigation.

---

## 4. Lab 01 — DNS Record Not Resolving

**Scenario:** A hostname fails to resolve because the expected DNS record is missing or the query is directed to the wrong DNS authority.

### Investigation

- Examine hosted zones.
- Inspect record sets.
- Query authoritative nameservers.
- Use `dig` and `nslookup`.
- Understand `NXDOMAIN` and `NOERROR` responses.
- Verify DNS delegation where applicable.

### Expected Outcome

Identify the missing or incorrectly configured DNS record and verify successful resolution after remediation.

---

## 5. Lab 02 — Wrong A Record

**Scenario:** A hostname resolves successfully but returns the wrong IPv4 address.

### Investigation

- Inspect the configured A record.
- Compare expected and actual IP addresses.
- Query authoritative DNS.
- Investigate endpoint connectivity.
- Correct the record.

### Expected Outcome

Restore the correct IPv4 mapping and verify DNS resolution and application connectivity.

---

## 6. Lab 03 — CNAME Misconfiguration

**Scenario:** An application hostname uses an incorrect CNAME destination or invalid DNS configuration.

### Investigation

- Inspect CNAME record values.
- Follow the DNS resolution chain.
- Understand CNAME restrictions.
- Investigate conflicting records.
- Verify the final target.

### Expected Outcome

Correct the CNAME configuration and verify that the intended destination resolves.

---

## 7. Lab 04 — DNS TTL and Caching Problem

**Scenario:** A DNS record is updated, but some clients continue resolving an older address.

### Investigation

- Understand Time to Live.
- Inspect record TTL values.
- Compare authoritative and recursive DNS responses.
- Investigate local DNS caching.
- Examine propagation behavior.

### Expected Outcome

Identify whether the issue is an authoritative configuration error or a cached response and verify the updated record.

---

## 8. Lab 05 — Public vs Private Hosted Zone

**Scenario:** A DNS record resolves inside a VPC but fails from outside AWS, or a private name does not resolve in the intended VPC.

### Investigation

- Identify public and private hosted zones.
- Inspect VPC associations.
- Verify VPC DNS support.
- Test AmazonProvidedDNS.
- Compare internal and external queries.
- Review DNS visibility.

### Expected Outcome

Correct DNS placement or VPC association and verify that the hostname is accessible from the intended network.

---

## 9. Lab 06 — Incorrect Alias Record

**Scenario:** A Route 53 alias record targets the wrong AWS resource or uses an invalid alias configuration.

### Investigation

- Review alias target settings.
- Examine the AWS resource's DNS name.
- Inspect the hosted zone ID.
- Compare Alias and CNAME behavior.
- Verify resource routing.

### Expected Outcome

Correct the alias target and verify successful DNS resolution.

---

## 10. Lab 07 — Route 53 Health Check Failure

**Scenario:** Route 53 reports an endpoint as unhealthy because of incorrect health check configuration or failed endpoint connectivity.

### Investigation

- Inspect health check settings.
- Verify HTTP, HTTPS, or TCP configuration.
- Check domain names and ports.
- Investigate endpoint responses.
- Review health check status and failure reasons.

### Expected Outcome

Identify and correct the health check configuration or endpoint failure.

---

## 11. Lab 08 — DNS Failover Not Working

**Scenario:** A primary endpoint fails, but Route 53 does not return the expected secondary DNS record.

### Investigation

- Examine failover routing policies.
- Verify PRIMARY and SECONDARY records.
- Inspect health check associations.
- Review health check status.
- Query authoritative DNS.
- Investigate DNS TTL.

### Expected Outcome

Restore correct DNS failover behavior and verify primary/secondary selection according to health status.

---

## 12. Lab 09 — Split-Horizon DNS Troubleshooting

**Scenario:** The same hostname intentionally or unintentionally resolves differently depending on whether the DNS query originates inside or outside the VPC.

### Investigation

- Configure separate public and private DNS views.
- Inspect VPC associations.
- Compare internal and external responses.
- Investigate overlapping zones.
- Verify the intended authoritative answer.

### Expected Outcome

Identify whether different DNS results are expected or caused by a misconfiguration, and restore the intended behavior.

---

## 13. Lab 10 — Route 53 Resolver Forwarding Problem

**Scenario:** DNS queries fail because a Route 53 Resolver forwarding rule is incorrect or an outbound endpoint cannot reach its configured DNS target.

### Investigation

- Examine Resolver forwarding rules.
- Verify VPC rule associations.
- Inspect inbound and outbound endpoints.
- Review DNS target addresses.
- Check security groups.
- Test TCP and UDP port 53.
- Investigate forwarding failures.

### Expected Outcome

Identify the forwarding or connectivity misconfiguration and restore the intended DNS resolution path.

---

## 14. Standard Troubleshooting Workflow

Each lab follows the same investigation process:

```text
1. Understand the Problem
          |
          v
2. Deploy Test Infrastructure
          |
          v
3. Verify Normal Behavior
          |
          v
4. Introduce a Controlled Failure
          |
          v
5. Reproduce the Symptoms
          |
          v
6. Investigate Using AWS CLI and Linux
          |
          v
7. Identify the Root Cause
          |
          v
8. Apply Remediation
          |
          v
9. Verify Successful Recovery
          |
          v
10. Delete Temporary Resources
```

Each lab README will document:

- Production incident scenario
- Symptoms and business impact
- AWS architecture
- Resource configuration
- Fault injection procedure
- Investigation commands
- Error messages
- Root cause analysis
- Five Whys analysis
- Remediation steps
- Verification commands
- Production best practices
- Troubleshooting interview questions
- Cleanup procedure
- Skills demonstrated
- Lessons learned

---

## 15. Essential DNS Commands

### DNS Resolution

```bash
dig example.com
```

### A Record

```bash
dig example.com A
```

### CNAME Record

```bash
dig www.example.com CNAME
```

### Nameserver Records

```bash
dig example.com NS
```

### SOA Record

```bash
dig example.com SOA
```

### Trace DNS Delegation

```bash
dig +trace example.com
```

### Query a Specific Nameserver

```bash
dig @1.1.1.1 example.com A
```

### Short Output

```bash
dig +short example.com
```

### Inspect DNS TTL

```bash
dig example.com A
```

The answer section shows the remaining TTL.

### nslookup

```bash
nslookup example.com
```

### System Hostname Resolution

```bash
getent ahostsv4 example.com
```

### Test HTTP Endpoint

```bash
curl -I https://example.com
```

### Test TCP Connectivity

```bash
nc -vz example.com 443
```

### List Route 53 Hosted Zones

```bash
aws route53 list-hosted-zones
```

### List DNS Records

```bash
aws route53 list-resource-record-sets \
  --hosted-zone-id YOUR_HOSTED_ZONE_ID
```

### Inspect Route 53 Health Checks

```bash
aws route53 list-health-checks
```

### List Resolver Rules

```bash
aws route53resolver list-resolver-rules \
  --region us-east-1
```

### List Resolver Endpoints

```bash
aws route53resolver list-resolver-endpoints \
  --region us-east-1
```

---

## 16. Important DNS Concepts

| Concept | Explanation |
|---|---|
| DNS | Converts domain names into DNS resource records |
| Hosted Zone | Container for DNS records |
| A Record | Maps a hostname to an IPv4 address |
| AAAA Record | Maps a hostname to an IPv6 address |
| CNAME | Maps an alias hostname to another hostname |
| Alias Record | Route 53-specific record mechanism for supported targets |
| NS Record | Identifies authoritative nameservers |
| SOA Record | Contains zone authority information |
| TTL | Controls how long DNS responses may be cached |
| NXDOMAIN | Requested DNS name does not exist |
| SERVFAIL | DNS server could not complete the request |
| Public Hosted Zone | Provides public DNS records |
| Private Hosted Zone | Provides DNS records within associated VPCs |
| Health Check | Monitors an endpoint or a specified health condition |
| Failover Routing | Selects primary or secondary answers according to health and policy |
| Split-Horizon DNS | Returns different DNS answers based on the DNS view |
| Resolver Endpoint | Connects DNS resolution between AWS and another network |
| Resolver Rule | Controls conditional DNS forwarding |

---

## 17. Security Best Practices

- Use least-privilege IAM permissions.
- Protect production hosted zones against unauthorized changes.
- Avoid accidental DNS record deletion.
- Validate DNS changes before deployment.
- Use infrastructure as code where appropriate.
- Keep private DNS records within the intended VPCs.
- Monitor Route 53 health checks.
- Record DNS changes and maintain rollback procedures.
- Avoid exposing internal-only services through public DNS unintentionally.
- Review Resolver endpoint security groups.
- Use secure DNS forwarding configurations.
- Remove unused hosted zones, health checks, and Resolver endpoints.

---

## 18. Cost Management and Lab Safety

Route 53 is not entirely free.

Depending on the exercises, AWS may charge for:

- Public hosted zones
- Private hosted zones
- DNS queries
- Health checks
- Resolver endpoints and their IP addresses
- EC2 troubleshooting instances
- Related network infrastructure

**Important:** Resolver endpoints can be especially expensive for extended lab sessions because AWS bills their endpoint IP addresses hourly. The final forwarding lab should use a tightly controlled deployment and cleanup procedure.

We will avoid purchasing domains unless explicitly required.

Public DNS labs requiring real internet delegation must use a domain or subdomain we control. Creating a public hosted zone alone does not establish delegation from the public DNS hierarchy.

For private DNS labs, we can use a dedicated test namespace that does not affect production DNS.

Each lab will include explicit cleanup commands.

---

## 19. Incident Documentation Standards

Each troubleshooting lab will be documented using a consistent format.

### Required Evidence

- Resource configuration
- Fault injection commands
- Observed DNS error
- Investigation results
- Root cause
- Remediation commands
- DNS verification
- Resource cleanup

### Investigation Principles

1. Verify the reported symptom.
2. Determine whether the failure is DNS or application connectivity.
3. Inspect authoritative DNS records.
4. Compare recursive and authoritative DNS responses.
5. Investigate DNS TTL and caching.
6. Identify the responsible AWS resource.
7. Apply the smallest safe correction.
8. Verify recovery from the appropriate network.
9. Document the root cause.
10. Clean up disposable infrastructure.

The documented result should reflect actual observations rather than assumed success.

---

## 20. Expected Learning Outcomes

After completing the ten labs, the learner should be able to:

- Troubleshoot Route 53 DNS records.
- Diagnose `NXDOMAIN` and other DNS errors.
- Correct A record and CNAME misconfigurations.
- Investigate caching and TTL problems.
- Differentiate public and private hosted zones.
- Troubleshoot Route 53 alias records.
- Investigate health check failures.
- Diagnose DNS failover routing problems.
- Understand split-horizon DNS.
- Investigate Route 53 Resolver forwarding.
- Use AWS CLI and Linux DNS utilities.
- Apply structured root cause analysis.
- Document and remediate DNS incidents.

---

## 21. Career Relevance

Amazon Route 53 troubleshooting is relevant to several engineering roles:

- Cloud Engineer
- Cloud Operations Engineer
- Cloud Security Engineer
- DevOps Engineer
- Site Reliability Engineer
- Infrastructure Engineer
- Platform Engineer

DNS issues can affect application availability, load balancer routing, private service discovery, hybrid networking, and security boundaries.

Understanding DNS behavior is particularly important for troubleshooting AWS-based production environments.

**Key Takeaway:** Reliable cloud networking requires more than creating DNS records. Engineers must understand authoritative resolution, caching, hosted-zone visibility, routing policies, endpoint health, and DNS forwarding to troubleshoot production incidents effectively.

---

## Project Status

| Milestone | Status |
|---|---|
| Repository Planning | Complete |
| Lab 01 — DNS Record Not Resolving | Planned |
| Lab 02 — Wrong A Record | Planned |
| Lab 03 — CNAME Misconfiguration | Planned |
| Lab 04 — DNS TTL and Caching Problem | Planned |
| Lab 05 — Public vs Private Hosted Zone | Planned |
| Lab 06 — Incorrect Alias Record | Planned |
| Lab 07 — Health Check Failure | Planned |
| Lab 08 — DNS Failover Not Working | Planned |
| Lab 09 — Split-Horizon DNS | Planned |
| Lab 10 — Resolver Forwarding | Planned |

The repository will be updated as each practical troubleshooting lab is completed.
