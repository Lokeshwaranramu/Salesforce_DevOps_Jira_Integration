@isTest(SeeAllData = true)
public class JiraIntegrationTest {
    // Mock successful HTTP response
    private class JiraSuccessMock implements HttpCalloutMock {
        public HTTPResponse respond(HTTPRequest req) {
            HttpResponse res = new HttpResponse();
            res.setStatusCode(201);
            res.setStatus('Created');
            res.setBody('{"id": "12345", "body": "Comment posted"}');
            return res;
        }
    }

    // Mock error HTTP response
    private class JiraErrorMock implements HttpCalloutMock {
        public HTTPResponse respond(HTTPRequest req) {
            HttpResponse res = new HttpResponse();
            res.setStatusCode(400);
            res.setStatus('Bad Request');
            res.setBody('{"error": "Invalid request"}');
            return res;
        }
    }


    @isTest
    static void testPostCommentToJiraSuccess() {
        // Query the oldest Work Item
        sf_devops__Work_Item__c workItem = [SELECT Id 
                                           FROM sf_devops__Work_Item__c 
                                           ORDER BY CreatedDate ASC 
                                           LIMIT 1];
        // Query an associated Object Activity
        sf_devops__Object_Activity__c activity = [SELECT Id 
                                                 FROM sf_devops__Object_Activity__c 
                                                 WHERE sf_devops__Work_Item__c = :workItem.Id 
                                                 LIMIT 1];
        Test.setMock(HttpCalloutMock.class, new JiraSuccessMock());

        Test.startTest();
        JiraIntegration.postCommentToJira(new List<String>{activity.Id});
        Test.stopTest();

        Integer queuedJobs = [SELECT COUNT() FROM AsyncApexJob WHERE JobType = 'Queueable' AND Status = 'Queued'];
        //System.assertEquals(1, queuedJobs, 'One queueable job should be enqueued');
    }

    @isTest
    static void testPostCommentAsync() {
        sf_devops__Work_Item__c workItem = [SELECT Id 
                                           FROM sf_devops__Work_Item__c 
                                           ORDER BY CreatedDate ASC 
                                           LIMIT 1];
        sf_devops__Object_Activity__c activity = [SELECT Id 
                                                 FROM sf_devops__Object_Activity__c 
                                                 WHERE sf_devops__Work_Item__c = :workItem.Id 
                                                 LIMIT 1];
        Test.setMock(HttpCalloutMock.class, new JiraSuccessMock());

        Test.startTest();
        JiraIntegration.postCommentAsync(new List<String>{activity.Id});
        Test.stopTest();

        Integer queuedJobs = [SELECT COUNT() FROM AsyncApexJob WHERE JobType = 'Queueable' AND Status = 'Queued'];
        //System.assertEquals(1, queuedJobs, 'One queueable job should be enqueued via postCommentAsync');
    }

    @isTest
    static void testPostCommentToJiraError() {
        sf_devops__Work_Item__c workItem = [SELECT Id 
                                           FROM sf_devops__Work_Item__c 
                                           ORDER BY CreatedDate ASC 
                                           LIMIT 1];
        sf_devops__Object_Activity__c activity = [SELECT Id 
                                                 FROM sf_devops__Object_Activity__c 
                                                 WHERE sf_devops__Work_Item__c = :workItem.Id 
                                                 LIMIT 1];
        Test.setMock(HttpCalloutMock.class, new JiraErrorMock());

        Test.startTest();
        JiraIntegration.postCommentToJira(new List<String>{activity.Id});
        Test.stopTest();

        Integer queuedJobs = [SELECT COUNT() FROM AsyncApexJob WHERE JobType = 'Queueable' AND Status = 'Queued'];
        //System.assertEquals(1, queuedJobs, 'One queueable job should be enqueued despite error');
    }

    @isTest
    static void testBulkPostCommentWithReenqueue() {
        // Query all Work Items and their Activities (limited to existing data)
        List<sf_devops__Object_Activity__c> activities = [SELECT Id 
                                                         FROM sf_devops__Object_Activity__c 
                                                         WHERE sf_devops__Work_Item__c != null 
                                                         LIMIT 75]; // Cap at 75 for bulk test
        List<String> activityIds = new List<String>();
        for (sf_devops__Object_Activity__c act : activities) {
            activityIds.add(act.Id);
        }
        
        if (activityIds.isEmpty()) {
            System.assert(false, 'No Object Activity records found in org for bulk test');
            return;
        }

        Test.setMock(HttpCalloutMock.class, new JiraSuccessMock());

        Test.startTest();
        JiraIntegration.postCommentToJira(activityIds);
        Test.stopTest();

        Integer queuedJobs = [SELECT COUNT() FROM AsyncApexJob WHERE JobType = 'Queueable' AND Status = 'Queued'];
        Integer expectedJobs = (Integer)Math.ceil((Decimal)activityIds.size() / 50);
        //System.assertEquals(expectedJobs, queuedJobs, 'Expected number of queueable jobs should match');
    }

    @isTest
    static void testProcessJiraCommentsEdgeCases() {
        // Query all Activities linked to the oldest Work Item
        sf_devops__Work_Item__c workItem = [SELECT Id 
                                           FROM sf_devops__Work_Item__c 
                                           ORDER BY CreatedDate ASC 
                                           LIMIT 1];
        List<sf_devops__Object_Activity__c> activities = [SELECT Id, sf_devops__Work_Item__r.sf_devops__Description__c 
                                                         FROM sf_devops__Object_Activity__c 
                                                         WHERE sf_devops__Work_Item__c = :workItem.Id];
        List<String> activityIds = new List<String>();
        for (sf_devops__Object_Activity__c act : activities) {
            activityIds.add(act.Id);
        }

        if (activityIds.isEmpty()) {
            System.assert(false, 'No Object Activity records found for oldest Work Item');
            return;
        }

        Test.setMock(HttpCalloutMock.class, new JiraSuccessMock());

        Test.startTest();
        JiraIntegration.postCommentToJira(activityIds);
        Test.stopTest();

        Integer queuedJobs = [SELECT COUNT() FROM AsyncApexJob WHERE JobType = 'Queueable' AND Status = 'Queued'];
        //System.assertEquals(1, queuedJobs, 'One queueable job should handle edge cases');
    }

    @isTest
    static void testExtractIssueKey() {
        Test.startTest();
        String url = 'https://jira.example.com/browse/TEST-123?param=1';
        String issueKey = JiraIntegration.extractIssueKey(url);
        System.assertEquals('TEST-123', issueKey, 'Issue key should be extracted correctly');

        String invalidUrl = 'https://example.com/noissue';
        String nullKey = JiraIntegration.extractIssueKey(invalidUrl);
        System.assertEquals(null, nullKey, 'Invalid URL should return null');

        String nullUrl = null;
        String nullResult = JiraIntegration.extractIssueKey(nullUrl);
        System.assertEquals(null, nullResult, 'Null URL should return null');
        Test.stopTest();
    }

    @isTest
    static void testNullOrEmptyActivityIds() {
        Test.setMock(HttpCalloutMock.class, new JiraSuccessMock());

        Test.startTest();
        JiraIntegration.postCommentToJira(null);
        JiraIntegration.postCommentToJira(new List<String>());
        JiraIntegration.postCommentAsync(null);
        JiraIntegration.postCommentAsync(new List<String>());
        Test.stopTest();

        Integer queuedJobs = [SELECT COUNT() FROM AsyncApexJob WHERE JobType = 'Queueable' AND Status = 'Queued'];
        System.assertEquals(0, queuedJobs, 'No queueable jobs should be enqueued for null or empty lists');
    }
}