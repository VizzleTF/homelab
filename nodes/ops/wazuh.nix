# Security logging for the node: journald -> Wazuh.
#
# The node holds the GitOps source of truth and is the one machine reachable
# when the cluster is down, so its auth trail matters more than most. It gets
# no Wazuh agent: the only NixOS packaging is a community flake with two stars
# and no licence, and a container agent would watch the container, not the host
# (the stock config tails Debian paths like /var/log/auth.log, which NixOS does
# not have — everything lives in journald).
#
# Forwarding syslog costs one service and gives the parts that matter: sshd,
# sudo, systemd unit failures and Forgejo, all of which Wazuh already has
# decoders and rules for. The manager listens on 514/udp (LoadBalancer
# 10.11.10.140, see argocd/apps/wazuh) with allowed-ips covering 10.11.0.0/16.
#
# Deliberately not the whole journal: auth/authpriv plus warnings and above.
# The full stream is mostly build and service chatter that no rule matches.
{ ... }:

{
  services.rsyslogd = {
    enable = true;
    defaultConfig = ''
      # imjournal reads the journal directly, so journald needs no
      # ForwardToSyslog and nothing is written to disk twice.
      module(load="imjournal" StateFile="imjournal.state")

      # RFC3164 (traditional): Wazuh's decoders are written against it, the
      # newer RFC5424 format makes predecoding lose the program name.
      auth,authpriv.*  action(type="omfwd" target="10.11.10.140" port="514"
                              protocol="udp" template="RSYSLOG_TraditionalForwardFormat")
      *.warn           action(type="omfwd" target="10.11.10.140" port="514"
                              protocol="udp" template="RSYSLOG_TraditionalForwardFormat")
    '';
  };
}
