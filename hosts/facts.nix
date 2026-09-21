# Per-host identity that peers need to know about each other.

{
  laptop = {
    tailscale = "100.112.109.20";
    systems = [ "x86_64-linux" ];
  };

  desktopnew = {
    mac = "b4:2e:99:92:d6:18";
    interface = "enp5s0";
    tailscale = "100.106.140.88";
    hostKey = "c3NoLWVkMjU1MTkgQUFBQUMzTnphQzFsWkRJMU5URTVBQUFBSUVobFMzS3gzN25PaEU2bkFua1hnb0hVM0p3dEZMbVQxbUxiRkxjbUxYbDggcm9vdEBkZXNrdG9wCg==";
    systems = [
      "x86_64-linux"
      "aarch64-linux"
    ];
  };

  pi = {
    tailscale = "100.117.13.66";
    systems = [ "aarch64-linux" ];
  };

  desktop_old = {
    mac = "70:85:c2:54:c6:89";
    interface = "enp6s0";
    systems = [ "x86_64-linux" ];
  };
}
