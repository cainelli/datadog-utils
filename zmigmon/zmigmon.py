from checks import AgentCheck
from zutils.zimbra import ZimbraRequest

class ZimbraMigMonitor(AgentCheck):
    """This check provides metrics on the number of GB used of a domain.

    YAML config options:
        "zimbra_url" - zimbra admin url ex.: https://172.0.0.51:7071
        "zimbra_user" - zimbra user with privileges to getQuotaUsage
        "zimbra_pass" - zimbra user's password.
    """
    def check(self, instances):

        domain = instances['domain']
        zimbra_url = instances.get('zimbra_url', self.init_config.get('zimbra_url'))
        zimbra_user = instances.get('zimbra_user', self.init_config.get('zimbra_user'))
        zimbra_pass = instances.get('zimbra_pass', self.init_config.get('zimbra_pass'))

        self._get_quota_count(zimbra_url, zimbra_user, zimbra_pass, domain)


    def _get_quota_count(self, zimbra_url, zimbra_user, zimbra_pass, domain):
        zr = ZimbraRequest(zimbra_url, zimbra_user, zimbra_pass)

        res = zr.getDomainQuotaUsage(domain)
        count = 0
        for account in res['GetQuotaUsageResponse']['account']:
            count = count + account['used']

        self.gauge('zmigmon.quota.usage', count, tags=['domain:%s' % domain])
