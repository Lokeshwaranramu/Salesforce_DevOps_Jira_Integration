# Salesforce DevOps Center to JIRA Integration

A custom integration that posts updates from Salesforce DevOps Center to JIRA tickets using Apex and Flow. No third-party apps required!

## Features
- Automatically posts comments to JIRA tickets when an `sf_devops__Object_Activity__c` record is created.
- Includes Activity details (Work Item, Activity Type, Summary, Commit URL) in the JIRA comment.
- Uses Queueable Apex to handle HTTP callouts asynchronously, respecting governor limits.
- Configurable via Named Credentials for secure JIRA authentication.

## Documentation

# Salesforce DevOps Center to JIRA Integration Overview

This outlines the integration of JIRA with Salesforce DevOps Center using a custom Apex class (`JiraIntegration`). The integration automatically posts comments to JIRA tickets whenever an `sf_devops__Object_Activity__c` record is created in Salesforce DevOps Center. This is achieved through a Flow trigger that invokes the Apex class, leveraging asynchronous processing to comply with Salesforce governor limits and trigger restrictions. The class connects to JIRA via a Named Credential and uses data from the Activity record to construct meaningful comments.

## Purpose

The integration enhances visibility and collaboration between Salesforce DevOps Center and JIRA by:

- **Posting Activity Details**: Automatically posts details (e.g., Work Item, Activity Type, Summary, Commit URL) to related JIRA tickets.
- **Automating Updates**: Keeps development and issue tracking in sync without manual intervention.
- **Supporting Asynchronous Execution**: Handles HTTP callouts outside the trigger context to comply with Salesforce limitations.

This solution is particularly valuable for organizations using Salesforce DevOps Center for CI/CD processes and JIRA for issue tracking, as it ensures seamless communication between development and project management teams without the need for paid third-party tools.

## Prerequisites

Before setting up this integration, ensure the following are in place:

- **Salesforce DevOps Center**: Installed in your Salesforce org (Setup > DevOps Center).
- **JIRA Instance**: Access to a JIRA instance (e.g., `https://<domain>.atlassian.net`).
- **Named Credential**: Configured for JIRA authentication (see setup instructions below).
- **Flow**: A record-triggered Flow on `sf_devops__Object_Activity__c` creation (provided in the repository).
- **Permissions**: Admin access to deploy Apex classes and configure Flows.
- **Apex Class**: The `JiraIntegration` class (included in the repository).

## Setup Instructions

Follow these steps to set up the integration in your Salesforce org.

### Step 1: Configure Named Credential for JIRA

1. Go to **Setup > Named Credentials** in Salesforce.
2. Click **New Named Credential**.
3. Configure the following:
   - **Label**: `JIRA_Credential`
   - **Name**: `JIRA_Credential` (must match the constant in the Apex class)
   - **URL**: Your JIRA instance base URL (e.g., `https://<domain>.atlassian.net`)
   - **Identity Type**: Named Principal (for org-wide use)
   - **Authentication Protocol**: Password Authentication
   - **Username**: Your JIRA username (email address)
   - **Password**: JIRA API token (generate from JIRA > Profile > Security > API Tokens)
   - **Generate Authorization Header**: Checked
4. Save and test the connection to ensure it works.

### Step 2: Deploy the Apex Class

1. Deploy the `JiraIntegration.cls` file (located in `classes/`) to your Salesforce org.
   - Use an IDE like VS Code with the Salesforce Extension Pack, or deploy via a Change Set.
2. Ensure all referenced custom objects (`sf_devops__Object_Activity__c`, `sf_devops__Work_Item__c`, etc.) exist and are accessible in your org. Usually this comes with the package.

### Step 3: Deploy and Activate the Flow

1. Deploy the Flow metadata file (`DevOps_to_JIRA.flow-meta.xml`) located in `force-app/main/default/flows/`.
- Use the same deployment command as above.
2. Go to **Setup > Flows** in Salesforce.
3. Find the Flow named `DevOps to JIRA` and ensure it’s active.
- If it’s not active, click the Flow name and toggle the status to **Active**.

### Step 4: Test the Integration

1. Create an `sf_devops__Object_Activity__c` record in Salesforce with the following:
- A related `sf_devops__Work_Item__c` record where the `sf_devops__Description__c` field contains a valid JIRA URL (e.g., `https://<domain>.atlassian.net/browse/D-1411`).
- Optional: Populate `sf_devops__Change_Submission__c` and `sf_devops__Project__c` fields to include commit details in the comment.
2. Save the record and check the corresponding JIRA ticket for the posted comment.

## How It Works

The integration operates as follows:

1. **Flow Trigger**: When an `sf_devops__Object_Activity__c` record is created, the `DevOps to JIRA` Flow is triggered (after save).
2. **Invocable Method**: The Flow calls the `postCommentToJira` method in the `JiraIntegration` class, passing the Activity record ID.
3. **Queueable Job**: The `postCommentToJira` method enqueues a `JiraCommentQueueable` job to handle the HTTP callout asynchronously (required due to trigger restrictions on synchronous callouts).
4. **Processing**:
- The `JiraCommentQueueable` job queries the Activity record and its related fields.
- Extracts the JIRA issue key (e.g., `D-1411`) from the `sf_devops__Work_Item__r.sf_devops__Description__c` field using regex.
- Builds a comment with Activity details (e.g., Work Item, Activity Type, Summary, Timestamp, Commit URL).
- Posts the comment to the JIRA ticket via the REST API using the `JIRA_Credential` Named Credential.
5. **Error Handling**: The solution skips invalid records (e.g., missing JIRA URLs) and logs errors via `System.debug` for troubleshooting.

## Example JIRA Comment

Here’s an example of what a JIRA comment might look like after the integration runs:

Activity from Salesforce Work Item: WI-001
Activity Type: Development
Summary: Added new field to Account
Timestamp: 2025-04-09 10:00:00
Commit: https://bitbucket.org/repo/commits/abc123


## Troubleshooting

### Error: "Callout from triggers not supported"
- **Fix**: Ensure the Flow uses the `postCommentToJira` invocable method, which enqueues the job asynchronously. The Flow should be set to run "After Save" to avoid synchronous callout issues.

### Error: "Permission denied for Named Credential"
- **Fix**: Verify the `JIRA_Credential` Named Credential setup and ensure the running user has access (Setup > Named Credentials). Check the username and API token in JIRA.

### No Comment Posted
- **Check Debug Logs**: Review debug logs for errors (Setup > Debug Logs). Look for messages logged by the `logDebug` method in the `JiraIntegration` class.
- **Validate JIRA URL**: Ensure the `sf_devops__Work_Item__r.sf_devops__Description__c` field contains a valid JIRA URL (e.g., `https://<domain>.atlassian.net/browse/D-1411`). The URL must include a recognizable issue key (e.g., `D-1411`).

### Governor Limit Issues
- **Fix**: The `JiraIntegration` class batches requests to stay within callout limits (50 per batch). If you’re still hitting limits, reduce the number of `sf_devops__Object_Activity__c` records processed in a single transaction or check for other callouts in your org.

## Additional Notes

- **Scalability**: The solution uses Queueable Apex to handle large volumes of Activity records, batching requests to avoid governor limit issues.
- **Security**: Named Credentials securely store JIRA authentication details, ensuring no hardcoded credentials in the code.
- **Customization**: You can modify the `buildCommentBody` method in `JiraIntegration.cls` to include additional fields or format the comment differently.

This integration provides a cost-effective, native way to bridge Salesforce DevOps Center and JIRA, enhancing collaboration and visibility for CI/CD processes.
