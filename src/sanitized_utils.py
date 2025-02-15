import email
from email import policy
import re
from urllib.parse import urlparse, quote
from bs4 import BeautifulSoup
from botocore.exceptions import ClientError

# This is a placeholder for the original import statement
# Replace this with the actual import based on your application's structure
# from app import workmail_message_flow, s3, logger

# Video conferencing URL patterns
[sanitized]_PATTERNS = [
    # Zoom patterns
    r'https://[^/]*zoom\.us/j/\d+(?:\?pwd=[\w\d]+)?',
    r'https://[^/]*zoom\.us/s/\d+(?:\?pwd=[\w\d]+)?',
    r'https://[^/]*zoom\.us/meeting/\d+(?:\?pwd=[\w\d]+)?',
    # Microsoft Teams patterns
    r'https://teams\.microsoft\.com/l/meetup-join/[\w\d%-]+',
    r'https://teams\.live\.com/meet/[\w\d-]+',
    # AWS Chime patterns
    r'https://[\w\d-]+\.chime\.aws/[\w\d-]+',
    r'https://app\.chime\.aws/meetings/[\w\d-]+',
    # Google Meet patterns
    r'https://meet\.google\.com/[\w\d-]+',
    r'https://hangouts\.google\.com/[\w\d/]+'
]

def download_email(message_id):
    """Download email from WorkMail with proper policy settings."""
    # This is a placeholder for the original function call
    # Replace this with the actual call based on your application's structure
    # response = workmail_message_flow.get_raw_message_content(messageId=message_id)
    # email_content = response['messageContent'].read()
    email_content = b'' # Replace with sample email content for testing
    email_generation_policy = policy.SMTP.clone(refold_source='none')
    # This is a placeholder for the original log statement
    # Replace this with the actual log statement based on your application's structure
    # logger.info("Downloaded email from WorkMail successfully")
    return email.message_from_bytes(email_content, policy=email_generation_policy)

def get_charset_and_cte(part):
    """Get charset and content-transfer-encoding from email part."""
    transfer_encoding = part.get('Content-Transfer-Encoding')
    transfer_encoding = transfer_encoding.lower() if transfer_encoding else None
    charset = part.get_content_charset() or 'utf-8'
    return charset, transfer_encoding

def should_skip_url(url):
    """Determine if URL should be skipped based on patterns."""
    parsed_url = urlparse(url)
    if parsed_url.netloc == 'check.example.com:
        return True
    url_string = url.strip()
    return any(re.match(pattern, url_string) for pattern in [sanitized]_PATTERNS)

def find_and_replace_urls(content, content_type='text/plain'):
     """Find and replace URLs in email content with [sanitized] URLs."""
     if not content:
         return content, False
     
     url_pattern = r'https?://(?:[\w\d-]+\.)+[\w\d-]+(?:/[^\s<>"\']*[\w\d/])?(?:\?[^\s<>"\']*[\w\d=])?'
     modified = False
     
     if content_type == 'text/plain':
         last_end = 0
         new_content = ""
         try:
             for match in re.finditer(url_pattern, content):
                 url = match.group(0)
                 start, end = match.span()
                 new_content += content[last_end:start]
                 if not should_skip_url(url):
                     safe_url = quote(url, safe=':/?=&')  # Explicitly specify safe chars
                     new_content += f"https://check.example.com/check?url={safe_url}"
                     modified = True
                 else:
                     new_content += url
                 last_end = end
             new_content += content[last_end:]
             return new_content, modified
         except UnicodeEncodeError:
             return content, False
             
     elif content_type == 'text/html':
         try:
             soup = BeautifulSoup(content, 'html.parser', from_encoding='utf-8')
             for a_tag in soup.find_all('a', href=True):
                 url = a_tag['href']
                 if url.startswith('http') and not should_skip_url(url):
                     safe_url = quote(url, safe=':/?=&')
                     a_tag['href'] = f"https://check.example.com/check?url={safe_url}"
                     modified = True
             return str(soup), modified
         except UnicodeEncodeError:
             return content, False
def update_message_content(part):
    """Update email part content with [sanitized]s."""
    content_type = part.get_content_type()
    
    if (content_type not in ['text/plain', 'text/html'] or
        content_type in ['text/calendar', 'application/ics'] or
        part.get_filename() is not None or
        part.get('Content-Disposition', '').lower().startswith('attachment')):
        return False

    try:
        charset, transfer_encoding = get_charset_and_cte(part)
        content = part.get_content()
        new_content, modified = find_and_replace_urls(content, content_type)
        
        if modified:
            if charset.lower() == 'utf-8' and transfer_encoding == '7bit':
                transfer_encoding = 'quoted-printable'
                
            if content_type == 'text/html':
                part.set_content(new_content, subtype='html', 
                               charset=charset,
                               cte=transfer_encoding)
            else:
                part.set_content(new_content, subtype='plain', 
                               charset=charset,
                               cte=transfer_encoding)
        return modified
    except UnicodeError:
        return False

def update_workmail(message_id, updated_email, bucket_name):
    """Update email in WorkMail via S3."""
    if not bucket_name:
        raise ValueError("UPDATED_EMAIL_S3_BUCKET not set in environment")
    
    s3_key = f"mail/{message_id}"
    try:
        # Upload to S3 first
        # This is a placeholder for the original log statement
        # Replace this with the actual log statement based on your application's structure
        # logger.debug(f"Uploading modified message to S3: {s3_key}")
        # This is a placeholder for the original function call
        # Replace this with the actual call based on your application's structure
        # s3.put_object(
        #     Body=updated_email.as_bytes(),
        #     Bucket=bucket_name,
        #     Key=s3_key,
        #     ContentType='message/rfc822',
        #     ServerSideEncryption='AES256'
        # )
        
        content = {
            's3Reference': {
                'bucket': bucket_name,
                'key': s3_key
            }
        }
        
        # Try to update WorkMail
        # This is a placeholder for the original log statement
        # Replace this with the actual log statement based on your application's structure
        # logger.debug("Attempting to update WorkMail with modified content")
        # This is a placeholder for the original function call
        # Replace this with the actual call based on your application's structure
        # workmail_message_flow.put_raw_message_content(messageId=message_id, content=content)
        # This is a placeholder for the original log statement
        # Replace this with the actual log statement based on your application's structure
        # logger.info("Updated email sent to WorkMail successfully")
        
    except ClientError as e:
        if e.response['Error']['Code'] == 'MessageRejected':
            # This is a placeholder for the original log statement
            # Replace this with the actual log statement based on your application's structure
            # logger.error(f"WorkMail rejected message update: {str(e)}")
            # Rename the S3 object instead of deleting it
            error_key = f"{s3_key}.error"
            try:
                # Copy the object with new key
                # This is a placeholder for the original function call
                # Replace this with the actual call based on your application's structure
                # s3.copy_object(
                #     CopySource={'Bucket': bucket_name, 'Key': s3_key},
                #     Bucket=bucket_name,
                #     Key=error_key,
                #     MetadataDirective='COPY'
                # )
                # Delete the original
                # This is a placeholder for the original function call
                # Replace this with the actual call based on your application's structure
                # s3.delete_object(Bucket=bucket_name, Key=s3_key)
                # This is a placeholder for the original log statement
                # Replace this with the actual log statement based on your application's structure
                # logger.debug(f"Preserved error email at: {error_key}")
            except Exception as rename_error:
                # This is a placeholder for the original log statement
                # Replace this with the actual log statement based on your application's structure
                # logger.warning(f"Failed to preserve error email: {str(rename_error)}")
            raise
        raise
}