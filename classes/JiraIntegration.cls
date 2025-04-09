public class JiraIntegration {
    // Named Credential name for JIRA authentication
    private static final String JIRA_NAMED_CREDENTIAL = 'JIRA_Credential';
    private static final String JIRA_COMMENT_ENDPOINT = '/rest/api/2/issue/{issueId}/comment';
    private static final Integer MAX_CALLOUTS_PER_BATCH = 50; // Conservative limit to stay under 100 callouts

    /**
     * Wrapper class for JIRA comment request body
     */
    public class CommentRequest {
        public String body;

        public CommentRequest(String commentBody) {
            this.body = commentBody;
        }
    }

    /**
     * Invocable method to enqueue JIRA comment posting from Flow
     */
    @InvocableMethod(label='Post Comment to JIRA' description='Queues comments to be posted to JIRA based on Activity records')
    public static void postCommentToJira(List<String> activityIds) {
        if (activityIds != null && !activityIds.isEmpty()) {
            splitAndEnqueueJobs(activityIds);
        }
    }

    /**
     * Aura-enabled method to enqueue JIRA comment job
     */
    @AuraEnabled
    public static void postCommentAsync(List<String> activityIds) {
        if (activityIds != null && !activityIds.isEmpty()) {
            splitAndEnqueueJobs(activityIds);
        }
    }

    /**
     * Splits large lists into smaller batches and enqueues jobs
     */
    private static void splitAndEnqueueJobs(List<String> activityIds) {
        Integer batchSize = MAX_CALLOUTS_PER_BATCH;
        List<String> batch = new List<String>();

        for (Integer i = 0; i < activityIds.size(); i++) {
            batch.add(activityIds[i]);

            // Enqueue when batch is full or at the end of the list
            if (batch.size() == batchSize || i == activityIds.size() - 1) {
                System.enqueueJob(new JiraCommentQueueable(new List<String>(batch)));
                batch.clear(); // Reset batch for next set
            }
        }
    }

    /**
     * Core logic to process and post comments to JIRA tickets in bulk
     */
    private static void processJiraComments(List<String> activityIds) {
        List<sf_devops__Object_Activity__c> activities = queryActivities(activityIds);
        Map<String, String> issueKeyToComment = new Map<String, String>();
        Map<String, Id> issueKeyToActivityId = new Map<String, Id>();

        // Prepare comments in bulk, aggregating for duplicate issue keys
        for (sf_devops__Object_Activity__c acc : activities) {
            if (String.isBlank(acc.sf_devops__Work_Item__r?.sf_devops__Description__c)) {
                logDebug('JIRA Issue URL is not specified on the Work Item for Activity: ' + acc.Id);
                continue;
            }

            String issueKey = extractIssueKey(acc.sf_devops__Work_Item__r.sf_devops__Description__c);
            if (String.isBlank(issueKey)) {
                logDebug('Invalid JIRA Issue URL format for Activity: ' + acc.Id);
                continue;
            }

            String commentBody = buildCommentBody(acc);
            if (issueKeyToComment.containsKey(issueKey)) {
                // Aggregate comments for the same issue key
                issueKeyToComment.put(issueKey, issueKeyToComment.get(issueKey) + '\n\n' + commentBody);
            } else {
                issueKeyToComment.put(issueKey, commentBody);
                issueKeyToActivityId.put(issueKey, acc.Id); // Only store first activity ID for simplicity
            }
        }

        // Process comments in bulk
        if (!issueKeyToComment.isEmpty()) {
            bulkCreateJiraComments(issueKeyToComment, issueKeyToActivityId);
        }
    }

    /**
     * Queries activity records
     */
    private static List<sf_devops__Object_Activity__c> queryActivities(List<String> activityIds) {
        try {
            return [
                SELECT Id, Name, sf_devops__Activity_Type__c,
                       sf_devops__Summary__c, sf_devops__Work_Item__r.Name,
                       sf_devops__Work_Item__r.sf_devops__Description__c,
                       sf_devops__Target_Pipeline_Stage__r.sf_devops__Branch__r.sf_devops__Name__c,
                       sf_devops__Change_Submission__r.sf_devops__Remote_Reference__c,
                       sf_devops__Project__r.sf_devops__Platform_Repository__r.sf_devops__Url__c
                FROM sf_devops__Object_Activity__c
                WHERE Id IN :activityIds
                WITH SECURITY_ENFORCED
            ];
        } catch (Exception e) {
            logDebug('Error querying activities: ' + e.getMessage());
            return new List<sf_devops__Object_Activity__c>();
        }
    }

    /**
     * Extracts JIRA issue key from URL using regex for efficiency
     */
    public static String extractIssueKey(String jiraUrl) {
        if (String.isBlank(jiraUrl)) return null;

        try {
            // Match patterns like PROJECT-123 from URLs (e.g., /browse/PROJECT-123 or just PROJECT-123)
            Pattern p = Pattern.compile('[A-Z]+-\\d+');
            Matcher m = p.matcher(jiraUrl);
            if (m.find()) {
                return m.group();
            }
            return null;
        } catch (Exception e) {
            logDebug('Error extracting JIRA issue key: ' + e.getMessage());
            return null;
        }
    }

    /**
     * Constructs the comment body from Activity fields
     */
    private static String buildCommentBody(sf_devops__Object_Activity__c acc) {
        String comment = 'Activity from Salesforce Work Item: ' + (acc.sf_devops__Work_Item__r?.Name ?? 'N/A') + '\n';
        comment += 'Activity Type: ' + (acc.sf_devops__Activity_Type__c ?? 'N/A') + '\n';
        comment += 'Summary: ' + (acc.sf_devops__Summary__c ?? 'No Summary provided') + '\n';
        comment += 'Timestamp: ' + System.now().format();
        if (acc.sf_devops__Change_Submission__r?.sf_devops__Remote_Reference__c != null &&
            acc.sf_devops__Project__r?.sf_devops__Platform_Repository__r?.sf_devops__Url__c != null) {
            comment += '\nCommit: ' + acc.sf_devops__Project__r.sf_devops__Platform_Repository__r.sf_devops__Url__c +
                       '/commits/' + acc.sf_devops__Change_Submission__r.sf_devops__Remote_Reference__c;
        }
        return comment;
    }

    /**
     * Bulk posts comments to JIRA, re-enqueuing unprocessed requests
     */
    private static void bulkCreateJiraComments(Map<String, String> issueKeyToComment, Map<String, Id> issueKeyToActivityId) {
        Http http = new Http();
        List<HttpRequest> requests = new List<HttpRequest>();
        Map<HttpRequest, String> requestToIssueKey = new Map<HttpRequest, String>();
        List<String> unprocessedActivityIds = new List<String>();

        // Prepare all requests
        for (String issueKey : issueKeyToComment.keySet()) {
            HttpRequest request = new HttpRequest();
            String endpoint = 'callout:' + JIRA_NAMED_CREDENTIAL +
                             JIRA_COMMENT_ENDPOINT.replace('{issueId}', issueKey);
            request.setEndpoint(endpoint);
            request.setMethod('POST');
            request.setHeader('Content-Type', 'application/json');
            request.setHeader('Accept', 'application/json');
            CommentRequest commentReq = new CommentRequest(issueKeyToComment.get(issueKey));
            request.setBody(JSON.serialize(commentReq));
            requests.add(request);
            requestToIssueKey.put(request, issueKey);
        }

        // Send requests in bulk (within governor limits)
        Integer calloutCount = 0;
        for (HttpRequest req : requests) {
            if (calloutCount >= Limits.getLimitCallouts() - 1) {
                // Re-enqueue unprocessed requests
                unprocessedActivityIds.add(issueKeyToActivityId.get(requestToIssueKey.get(req)));
                continue;
            }
            try {
                HttpResponse response = http.send(req);
                String issueKey = requestToIssueKey.get(req);
                if (response.getStatusCode() == 201) {
                    logDebug('Successfully posted comment to JIRA ticket: ' + issueKey);
                } else {
                    logDebug('JIRA API Error for Activity ' + issueKeyToActivityId.get(issueKey) +
                             ': ' + response.getStatusCode() + ' - ' + response.getBody());
                }
            } catch (Exception e) {
                String issueKey = requestToIssueKey.get(req);
                logDebug('Failed to post comment for Activity ' + issueKeyToActivityId.get(issueKey) +
                         ': ' + e.getMessage());
            }
            calloutCount++;
        }

        // Re-enqueue any unprocessed activities
        if (!unprocessedActivityIds.isEmpty()) {
            splitAndEnqueueJobs(unprocessedActivityIds);
        }
    }

    /**
     * Utility method to conditionally log debug messages
     */
    private static void logDebug(String message) {
            System.debug(message);
    }

    /**
     * Queueable class for asynchronous execution
     */
    public class JiraCommentQueueable implements Queueable, Database.AllowsCallouts {
        private List<String> activityIds;

        public JiraCommentQueueable(List<String> activityIds) {
            this.activityIds = activityIds;
        }

        public void execute(QueueableContext context) {
            processJiraComments(activityIds);
        }
    }

    /**
     * Custom exception class
     */
    public class JiraException extends Exception {}
}