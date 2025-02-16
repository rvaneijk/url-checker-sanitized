Copyright (c) 2024 Rob van Eijk

Permission to use, copy, modify, and/or distribute this software for any purpose with or without fee is hereby granted, provided that the above copyright notice and this permission notice appear in all copies.

THE SOFTWARE IS PROVIDED "AS IS" AND THE AUTHOR DISCLAIMS ALL WARRANTIES WITH REGARD TO THIS SOFTWARE INCLUDING ALL IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS. IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR ANY SPECIAL, DIRECT, INDIRECT, OR CONSEQUENTIAL DAMAGES OR ANY DAMAGES WHATSOEVER RESULTING FROM LOSS OF USE, DATA OR PROFITS, WHETHER IN AN ACTION OF CONTRACT, NEGLIGENCE OR OTHER TORTIOUS ACTION, ARISING OUT OF OR IN CONNECTION

**This code has been sanitized, meaning all sensitive information like passwords, API keys, and internal system details have been removed and replaced with example values.**

# WorkMail URL Rewriter with AWS Lambda

This project implements an AWS WorkMail integration that processes incoming emails using AWS Lambda. The system enhances email security by rewriting URLs through a security checking service, with built-in security features and lifecycle management.

## Architecture Overview

The solution consists of multiple AWS CloudFormation stacks that create a complete email processing pipeline:

```
┌─────────────────┐     ┌──────────────┐     ┌───────────────┐
│  AWS WorkMail   │────>│ AWS Lambda   │────>│   AWS S3      │
└─────────────────┘     └──────────────┘     └───────────────┘
        │                      │                     │
        │                      │                     │
        └──────────────────────┴─────────────────────┘
                   IAM Permissions
```

### Stack Components

1. **Domain Stack** (Domain & Certificate Management)
   - Manages DNS configurations for your custom domain
   - Handles SSL/TLS certificates through AWS Certificate Manager
   - Configures Route53 DNS records and hosted zone integration

2. **API Base Stack** (API Infrastructure)
   - Sets up base API infrastructure with URL security checking
   - Configures Lambda function for URL verification
   - Implements API Gateway with CORS and security headers
   - Sets up CloudWatch monitoring and alerts

3. **API Mapping Stack** (API Gateway)
   - Creates API stage configuration
   - Sets up domain mapping
   - Configures access logging
   - Manages environmental variables per stage

4. **WorkMail Stack** (WorkMail Integration)
   - Configures WorkMail Lambda integration
   - Sets up S3 storage with security policies
   - Implements email processing logic
   - Creates CloudWatch dashboard for monitoring

### Security Features

- S3 bucket encryption using AES256
- Complete public access blocking
- IAM role-based access control
- Secure WorkMail message flow integration
- HTTPS-only API endpoints
- Comprehensive security headers in API responses
- Protected URL checking with security service integration
- Access logging and monitoring

### Data Retention Policies

The S3 bucket implements the following lifecycle rules:

- **Mail Directory Cleanup**
  - Applies to objects in `mail/` prefix
  - Deletes objects after 1 day
  - Status: Enabled

- **Version Management**
  - Versioning enabled
  - Previous versions deleted after 1 day
  - Applies to `mail/` prefix

## Prerequisites

Before deploying this solution, ensure you have:

- AWS CLI installed and configured
- AWS SAM CLI installed
- Python 3.9 or later
- Bash shell environment
- Required AWS permissions for:
  - CloudFormation
  - Lambda
  - S3
  - WorkMail
  - IAM
  - API Gateway
  - CloudWatch
  - Route53
  - Secrets Manager
- URL security service API key (e.g., Google Safe Browsing)
- A registered domain and Route53 hosted zone

## Initial Configuration

1. Create Required Secrets:
   - Store your URL security service API key in AWS Secrets Manager
   - Note the secret name for stack deployment

2. Configure Domain Settings:
   - Ensure your domain is registered
   - Set up a Route53 hosted zone
   - Note the hosted zone ID

3. Update Configuration:
   - Replace placeholder domains with your domain
   - Update stack name prefix if desired
   - Configure CORS settings for your environment
   - Update secret name references

## Deployment Steps

### 1. Initial Setup

```bash
# Clone the repository
git clone <repository-url>
cd <repository-directory>

# Make scripts executable
chmod +x deploy-v2.sh workmail-package-v2.sh
```

### 2. Package the Lambda Function

```bash
./workmail-package-v2.sh
```

This script:
- Creates a Python virtual environment
- Installs dependencies
- Packages the Lambda function
- Uploads to S3

### 3. Deploy the Stacks

```bash
# Deploy all stacks
./deploy-v2.sh --deploy

# Or deploy individual stacks
./deploy-v2.sh --deploy --domain
./deploy-v2.sh --deploy --api-base
./deploy-v2.sh --deploy --api-mapping
./deploy-v2.sh --deploy --workmail
```

### 4. First Time WorkMail Stack Setup
```bash
./deploy-v2.sh --deploy --workmail  # Creates S3 bucket and deploys stack
./workmail-package-v2.sh  # Packages and uploads Lambda code
```

### 5. Update Existing WorkMail Stack

```bash
# Update Lambda package
./workmail-package-v2.sh

# Update stack
./deploy-v2.sh --update --workmail
```

## Stack Operations

### Create fresh package:
```bash
rm -rf build/
rm workmail-lambda.zip
./workmail-package-v2.sh --clean
```

### Validate Templates

```bash
./deploy-v2.sh --validate
```

### Cleanup Resources

```bash
./deploy-v2.sh --cleanup
```

### Simulate Deployment

```bash
./deploy-v2.sh --simulate
```

## Configuration

### Dependencies

Required Python packages are specified in `requirements.txt`. Key dependencies include:
- beautifulsoup4: HTML parsing for URL rewriting
- boto3: AWS SDK for Python
- botocore: Low-level AWS API client

### Environment Variables

The Lambda functions use the following environment variables:

#### WorkMail Function:
- `UPDATED_EMAIL_S3_BUCKET`: S3 bucket for storing processed emails
- `ENVIRONMENT`: Deployment environment (dev/prod)
- `MAIL_PREFIX`: Prefix for email storage in S3 (default: mail/)

#### URL Checker Function:
- `DEBUG`: Enable debug logging
- `DOMAIN_NAME`: API custom domain name
- `SECURITY_SERVICE_SECRET_NAME`: Name of security service API key secret
- `CORS_ORIGIN`: Allowed CORS origin

## Monitoring and Logging

The solution includes comprehensive monitoring:

- **CloudWatch Logs**
  - Lambda function logs
  - API Gateway access logs
  - WorkMail email event logs

- **CloudWatch Metrics Dashboard**
  - Email processing statistics
  - Lambda performance metrics
  - Error rates and success rates
  - API request metrics

- **Alarms**
  - Lambda execution errors
  - API errors
  - Configuration available in CloudFormation templates

## Security Considerations

1. **S3 Bucket**:
   - Server-side encryption enabled
   - Public access blocked
   - Versioning enabled
   - Strict IAM policies

2. **Lambda Functions**:
   - Execution role with minimal permissions
   - Environment variable encryption
   - VPC configuration available
   - X-Ray tracing enabled

3. **API Gateway**:
   - HTTPS only
   - API key authentication
   - Resource policies
   - Comprehensive security headers

## Development Notes

### Error Handling

- Failed URL rewrites are preserved with `.error` suffix in S3
- Message validation failures result in delivery of original email
- Comprehensive logging of all processing steps
- CloudWatch dashboard for monitoring error rates

### Code Organization

- `app.py`: Main Lambda handler and core email processing
- `utils.py`: Helper functions for URL rewriting and email handling
- CloudFormation templates for each stack component
- Deployment scripts with validation and rollback support

### Adding Safe Senders

To add email addresses to the safe senders list (emails that skip URL rewriting):
1. Modify the `SAFE_SENDERS` set in `app.py`
2. Deploy updated Lambda code using provided scripts

### Debugging

For development and troubleshooting:
```bash
# Enable verbose output in packaging
./workmail-package-v2.sh --verbose

# List virtual environment details
./workmail-package-v2.sh --list-env

# Create fresh build
./workmail-package-v2.sh --clean
```

## Troubleshooting

### Common Issues

1. Certificate Validation:
   - Ensure DNS validation records are properly created
   - Wait for certificate validation (can take up to 30 minutes)
   - Verify domain ownership

2. WorkMail Integration:
   - Check WorkMail organization ID is correct
   - Verify Lambda execution role permissions
   - Monitor CloudWatch logs for errors

3. S3 Access:
   - Verify bucket policies
   - Check Lambda role permissions
   - Ensure encryption settings are correct

### Getting Help

- Check CloudWatch logs for detailed error messages
- Review IAM roles and permissions
- Verify all required resources are properly configured
- Ensure all placeholders are replaced with actual values

## License

This project is licensed under the MIT License