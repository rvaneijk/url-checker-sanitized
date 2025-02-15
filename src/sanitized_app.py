import logging
import os

# Import boto3 for AWS interaction
import boto3
from botocore.exceptions import ClientError

# Initialize logging for debugging and information
logger = logging.getLogger()
logger.setLevel(logging.DEBUG)

# Import utility functions (assuming these are in a separate 'utils.py' file)
from utils import (
    download_email,
    update_message_content,
    update_workmail
)

def deduplicate_headers(msg, processed_parts=None):
    """
    Remove duplicate headers from email messages to prevent validation errors.

    Args:
        msg: The email message object to process.
        processed_parts: A set to track processed message parts (for recursion).

    Returns:
        The modified email message object with duplicate headers removed.
    """
    if processed_parts is None:
        processed_parts = set()

    # Skip processing if this part has already been processed
    if id(msg) in processed_parts:
        return msg
    processed_parts.add(id(msg))

    # Process headers, removing duplicates of specific types
    headers_seen = set()
    headers_to_remove =
    if hasattr(msg, '_headers'):
        for header in msg._headers:
            header_name = header.lower()
            if header_name in ['precedence', 'content-type', 'content-transfer-encoding']:
                if header_name in headers_seen:
                    headers_to_remove.append(header)
                else:
                    headers_seen.add(header_name)

        for header in headers_to_remove:
            msg._headers.remove(header)

    # Recursively process child parts (without using walk())
    if msg.is_multipart():
        for part in msg.get_payload():
            deduplicate_headers(part, processed_parts)

    return msg

# Safe sender list - emails from these addresses don't need URL rewriting
SAFE_SENDERS = {
    'noreply@example.com'
}

def rewrite_handler(event, context):
    """
    AWS Lambda handler for processing WorkMail messages.

    Modifies email URLs by wrapping them with check.example.com, while preserving
    calendar invitations, attachments, and video conferencing links.

    Args:
        event: The event data passed to the Lambda function.
        context: The runtime information of the Lambda function.
    """
    logger.info("=== Starting email processing workflow ===")
    logger.debug(f"Lambda function ARN: {context.invoked_function_arn}")
    logger.debug(f"Lambda request ID: {context.aws_request_id}")

    # Log complete event structure with clear marker
    logger.debug("=== FULL EVENT STRUCTURE START ===")
    logger.debug(event)
    logger.debug("=== FULL EVENT STRUCTURE END ===")

    # Check if sender is in safe list
    from_address = event.get('envelope', {}).get('mailFrom', {}).get('address')
    if from_address in SAFE_SENDERS:
        logger.info(f"Skipping safe sender: {from_address}")
        return {
            'actions': [{'allRecipients': True, 'action': {'type': 'DEFAULT'}}]
        }

    message_id = event['messageId']
    logger.info(f"Processing message ID: {message_id}")

    try:
        # Initialize boto3 clients within the handler
        workmail_message_flow = boto3.client('workmailmessageflow')
        s3 = boto3.client('s3')

        # Download and parse email
        logger.debug("Attempting to download and parse email")
        parsed_msg = download_email(message_id)

        # Add header deduplication
        parsed_msg = deduplicate_headers(parsed_msg)
        message_modified = False

# Process each part of the message
        logger.debug("Beginning message content processing")
        if parsed_msg.is_multipart():
            logger.debug("Processing multipart message")
            for part in parsed_msg.walk():
                content_type = part.get_content_type()
                logger.debug(f"Processing part with content type: {content_type}")

                # Skip calendar parts and attachments
                if content_type == 'text/calendar' or \
                   content_type == 'application/ics' or \
                   part.get_filename() is not None:
                    logger.debug(f"Skipping part: {content_type}")
                    continue

                if update_message_content(part):
                    message_modified = True
                    logger.debug("Message part modified successfully")
        else:
            logger.debug("Processing single part message")
            message_modified = update_message_content(parsed_msg)

        if not message_modified:
            logger.info("No URLs to modify in message")
            return {
                'actions': [{'allRecipients': True, 'action': {'type': 'DEFAULT'}}]
            }

        # Update message in WorkMail
        bucket_name = os.getenv('UPDATED_EMAIL_S3_BUCKET')
        logger.debug(f"Attempting to update WorkMail with bucket: {bucket_name}")

        try:
            update_workmail(message_id, parsed_msg, bucket_name)
            logger.info("=== Email processing completed successfully ===")
        except ClientError as e:
            if e.response['Error']['Code'] == 'MessageRejected':
                logger.warning(f"Message validation failed - Return-Path format issue: {str(e)}")
                logger.info("Email will be delivered unmodified as per design")
                # Log metric for monitoring but don't trigger error alarm
                try:
                    cloudwatch = boto3.client('cloudwatch')
                    cloudwatch.put_metric_data(
                        Namespace='WorkMail/URLRewriter',
                        MetricData=[{
                            'MetricName': 'MessageRejectedCount',
                            'Value': 1,
                            'Unit': 'Count'
                        }]
                    )
                except Exception as metric_error:
                    logger.warning(f"Failed to log metric: {str(metric_error)}")
                return {
                    'actions': [{'allRecipients': True, 'action': {'type': 'DEFAULT'}}]
                }
            raise

except ClientError as e:
        if e.response['Error']['Code'] == 'MessageFrozen':
            logger.info(f"Message {message_id} not eligible for update - redirected email")
        else:
            error_code = e.response['Error']['Code']
            logger.error(f"AWS Client Error: {error_code}")
            if error_code == 'ResourceNotFoundException':
                logger.error(f"Message {message_id} does not exist")
            elif error_code == 'InvalidContentLocation':
                logger.error('WorkMail could not access updated email content')
            raise
    except Exception as e:
        logger.error(f"Unexpected error: {str(e)}")
        raise

    return {
        'actions': [
            {
                'allRecipients': True,
                'action': {'type': 'DEFAULT'}
            }
        ]
    }