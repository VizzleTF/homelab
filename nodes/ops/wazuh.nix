# journald -> Wazuh syslog, no agent: no maintained NixOS package, and a container
# agent watches the container, not the host. Manager: 514/udp on LoadBalancer
# 10.11.10.140 (argocd/apps/wazuh), allowed-ips 10.11.0.0/16.
# Only auth/authpriv + warn and above: the rest matches no rule.
{ ... }:

{
  services.rsyslogd = {
    enable = true;
    defaultConfig = ''
      # Reads the journal directly: no ForwardToSyslog needed.
      module(load="imjournal" StateFile="imjournal.state")

      # RFC3164: with RFC5424 Wazuh predecoding loses the program name.
      auth,authpriv.*  action(type="omfwd" target="10.11.10.140" port="514"
                              protocol="udp" template="RSYSLOG_TraditionalForwardFormat")
      *.warn           action(type="omfwd" target="10.11.10.140" port="514"
                              protocol="udp" template="RSYSLOG_TraditionalForwardFormat")
    '';
  };
}
