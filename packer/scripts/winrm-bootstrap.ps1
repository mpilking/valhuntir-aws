<powershell>
# Packer build only: enable WinRM over HTTPS (self-signed) so Packer can connect.
# The temporary security group admits 5986 only from the machine running Packer;
# the deployed Windows security group never opens 5986.
$ErrorActionPreference = "Stop"
Remove-Item -Path WSMan:\Localhost\listener\listener* -Recurse -ErrorAction SilentlyContinue
$cert = New-SelfSignedCertificate -CertStoreLocation Cert:\LocalMachine\My -DnsName "packer"
New-Item -Path WSMan:\LocalHost\Listener -Transport HTTPS -Address * -CertificateThumbPrint $cert.Thumbprint -Force
cmd.exe /c winrm set "winrm/config" '@{MaxTimeoutms="7200000"}'
cmd.exe /c winrm set "winrm/config/winrs" '@{MaxMemoryPerShellMB="2048"}'
cmd.exe /c winrm set "winrm/config/service/auth" '@{Basic="true"}'
cmd.exe /c netsh advfirewall firewall add rule name="WinRM-HTTPS-packer" dir=in action=allow protocol=TCP localport=5986
cmd.exe /c sc config winrm start= auto
cmd.exe /c net stop winrm
cmd.exe /c net start winrm
</powershell>
