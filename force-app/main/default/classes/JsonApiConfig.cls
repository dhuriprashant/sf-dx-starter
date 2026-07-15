/**
 * Central place to expose SObjects through the JSON:API framework.
 * Add a JsonApiRegistry.register(...) call per resource type you want served.
 */
public class JsonApiConfig {
    private static Boolean registered = false;

    public static void registerAll() {
        if (registered) {
            return;
        }
        registered = true;

        JsonApiRegistry.register(
            new JsonApiResourceDefinition('accounts', 'Account')
                .attribute('name', 'Name')
                .attribute('industry', 'Industry')
                .attribute('phone', 'Phone')
                .attribute('website', 'Website')
                .attribute('numberOfEmployees', 'NumberOfEmployees')
                .attribute('createdAt', 'CreatedDate')
                .toMany('contacts', 'contacts', 'AccountId')
                // contacts.reportsTo exposed as a direct alias: include=contactManagers
                // returns the managers without including the intermediate contacts
                .nested('contactManagers', new List<String>{ 'contacts', 'reportsTo' })
        );

        JsonApiRegistry.register(
            new JsonApiResourceDefinition('contacts', 'Contact')
                .attribute('firstName', 'FirstName')
                .attribute('lastName', 'LastName')
                .attribute('email', 'Email')
                .attribute('phone', 'Phone')
                .attribute('title', 'Title')
                .attribute('createdAt', 'CreatedDate')
                .toOne('account', 'AccountId', 'accounts')
                .toOne('reportsTo', 'ReportsToId', 'contacts')
        );
    }

    @TestVisible
    private static void reset() {
        registered = false;
        JsonApiRegistry.clear();
    }
}
