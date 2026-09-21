# PAM SSH-agent auth for sudo: challenge-response via a forwarded ssh-agent,
# no password. Requires AllowAgentForwarding on sshd and -A on the connection.

{ ... }:

{
  security.pam.sshAgentAuth = {
    enable = true;
    authorizedKeysFiles = [ "/etc/ssh/authorized_keys.d/max" ];
  };
  security.pam.services.sudo.sshAgentAuth = true;

  # sudo scrubs the environment before PAM runs, so without this the module
  # never sees the forwarded agent and always falls through to a password.
  security.sudo.extraConfig = "Defaults env_keep+=SSH_AUTH_SOCK";
}
