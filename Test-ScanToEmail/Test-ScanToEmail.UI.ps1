<#
.SYNOPSIS
    SMTP Diagnostics & Testing Tool - a self-contained GUI that submits a test
    message to any SMTP provider and shows the full server conversation.

.DESCRIPTION
    A single-file WPF app. Pick a provider preset (Microsoft 365, M365 High Volume
    Email, SendGrid, Amazon SES, Postmark, Mailgun, SMTP2GO, Brevo, Gmail/Workspace)
    or enter a host manually / look it up from a domain's MX record, then send a test
    message and read every line of the SMTP exchange (235/250/535/550/504 ...) in a
    dark, colour-coded transcript.

    It embeds its own raw-SMTP engine, so it's provider-agnostic and needs no other
    files - copy this one script anywhere and run it.

.NOTES
    Needs STA. Windows PowerShell 5.1 is STA by default:
        powershell.exe -File .\Test-ScanToEmail.UI.ps1
    PowerShell 7 is MTA, so force STA:
        pwsh -STA -File .\Test-ScanToEmail.UI.ps1
    Or right-click the file in Explorer and choose "Run with PowerShell".
#>

[CmdletBinding()]
param()

Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Xml

if ([System.Threading.Thread]::CurrentThread.GetApartmentState() -ne 'STA') {
    Write-Warning "Not running in STA - the window may misbehave. Launch with: powershell.exe -File .\Test-ScanToEmail.UI.ps1"
}

# =============================================================================
#  SMTP engine (embedded, provider-agnostic)
# =============================================================================
$script:Transcript = New-Object System.Collections.Generic.List[string]

function Write-Smtp {
    param([ValidateSet('C','S','I','E')][string]$Direction, [string]$Text)
    $tag = @{ C = 'C:'; S = 'S:'; I = '--'; E = '!!' }[$Direction]
    foreach ($line in ($Text -split "`r?`n")) { $script:Transcript.Add("$tag $line") }
}
function Send-SmtpLine {
    param([System.IO.Stream]$Stream, [string]$Line, [switch]$Secret)
    $bytes = [System.Text.Encoding]::ASCII.GetBytes($Line + "`r`n")
    $Stream.Write($bytes, 0, $bytes.Length); $Stream.Flush()
    if ($Secret) { Write-Smtp C '<redacted>' } else { Write-Smtp C $Line }
}
function Read-SmtpResponse {
    param([System.IO.Stream]$Stream)
    $sb = New-Object System.Text.StringBuilder
    $lineChars = New-Object System.Text.StringBuilder
    $code = $null
    while ($true) {
        $b = $Stream.ReadByte()
        if ($b -lt 0) { break }
        if ($b -eq 10) {
            $line = $lineChars.ToString().TrimEnd("`r")
            [void]$sb.AppendLine($line); $lineChars.Clear() | Out-Null
            if ($line.Length -ge 4 -and $line[3] -eq ' ') { $code = [int]$line.Substring(0,3); break }
            elseif ($line.Length -lt 4) { break }
        } else { [void]$lineChars.Append([char]$b) }
    }
    $text = $sb.ToString().TrimEnd("`r","`n")
    Write-Smtp S $text
    [pscustomobject]@{ Code = $code; Text = $text }
}
function Assert-Smtp {
    param($Response, [int[]]$Expected, [string]$Stage)
    if ($Response.Code -notin $Expected) {
        throw "SMTP $Stage failed: server replied $($Response.Code) (expected $($Expected -join '/')). $($Response.Text)"
    }
}
function Get-TlsStream {
    param([System.IO.Stream]$Inner, [string]$TargetHost, [bool]$SkipCheck)
    $cb = { param($s,$cert,$chain,$errs) if ($SkipCheck) { $true } else { $errs -eq [System.Net.Security.SslPolicyErrors]::None } }
    $ssl = New-Object System.Net.Security.SslStream($Inner, $false, $cb)
    $ssl.AuthenticateAsClient($TargetHost, $null, [System.Security.Authentication.SslProtocols]::None, $false)
    Write-Smtp I "TLS established: $($ssl.SslProtocol), cipher $($ssl.CipherAlgorithm) $($ssl.CipherStrength)-bit"
    $ssl
}
function New-MimeMessage {
    param([string]$From,[string[]]$To,[string]$Subject,[string]$Body,[string]$AttachmentPath)
    $nl = "`r`n"; $date = (Get-Date).ToString('r')
    $msgId = "<$([guid]::NewGuid().ToString('N'))@$(($From -split '@')[-1])>"
    $headers = @("From: $From","To: $($To -join ', ')","Subject: $Subject","Date: $date","Message-ID: $msgId","MIME-Version: 1.0")
    if ($AttachmentPath) {
        $boundary = "==Test_$([guid]::NewGuid().ToString('N'))"
        $fileName = [System.IO.Path]::GetFileName($AttachmentPath)
        $b64 = [Convert]::ToBase64String([System.IO.File]::ReadAllBytes($AttachmentPath))
        $wrapped = ($b64 -split '(.{76})' | Where-Object { $_ }) -join $nl
        $headers += "Content-Type: multipart/mixed; boundary=`"$boundary`""
        $body = @("--$boundary","Content-Type: text/plain; charset=UTF-8","Content-Transfer-Encoding: 8bit","",$Body,"","--$boundary","Content-Type: application/octet-stream; name=`"$fileName`"","Content-Transfer-Encoding: base64","Content-Disposition: attachment; filename=`"$fileName`"","",$wrapped,"","--$boundary--") -join $nl
    } else {
        $headers += "Content-Type: text/plain; charset=UTF-8"; $body = $Body
    }
    ($headers -join $nl) + $nl + $nl + $body
}
function Get-MxHosts {
    param([string]$Domain)
    $result = @()
    if (Get-Command Resolve-DnsName -ErrorAction SilentlyContinue) {
        try {
            $result = Resolve-DnsName -Name $Domain -Type MX -ErrorAction Stop |
                Where-Object { $_.QueryType -eq 'MX' -and $_.NameExchange } | Sort-Object Preference |
                ForEach-Object { [pscustomobject]@{ Preference = $_.Preference; Host = $_.NameExchange } }
        } catch { $result = @() }
    }
    if (-not $result) {
        try {
            $out = & nslookup -type=MX $Domain 2>$null
            $result = $out | Select-String 'mail exchanger\s*=\s*(\d+)\s+(\S+)' |
                ForEach-Object { [pscustomobject]@{ Preference = [int]$_.Matches[0].Groups[1].Value; Host = $_.Matches[0].Groups[2].Value.TrimEnd('.') } } |
                Sort-Object Preference
        } catch { $result = @() }
    }
    return $result
}

function Invoke-SmtpTest {
    param(
        [string]$From, [string[]]$To, [string]$SmtpServer, [bool]$Authenticate,
        [int]$Port, [string]$Encryption, [System.Management.Automation.PSCredential]$Credential,
        [string]$Subject, [string]$Body, [bool]$Attach, [bool]$SkipCertificateCheck,
        [int]$TimeoutSeconds = 30
    )
    $script:Transcript.Clear()
    $attachment = $null
    if ($Attach) {
        $attachment = Join-Path ([System.IO.Path]::GetTempPath()) ("smtptest_{0}.txt" -f (Get-Date -Format 'yyyyMMdd_HHmmss'))
        Set-Content -Path $attachment -Value "Test attachment generated by the SMTP Diagnostics tool at $(Get-Date)." -Encoding UTF8
    }
    $localFqdn = try { [System.Net.Dns]::GetHostEntry([string]$env:COMPUTERNAME).HostName } catch { $env:COMPUTERNAME }
    if (-not $localFqdn) { $localFqdn = $env:COMPUTERNAME }

    $client = $null; $stream = $null; $ok = $false; $errMsg = $null
    try {
        $client = New-Object System.Net.Sockets.TcpClient
        $iar = $client.BeginConnect($SmtpServer, $Port, $null, $null)
        if (-not $iar.AsyncWaitHandle.WaitOne([TimeSpan]::FromSeconds($TimeoutSeconds))) {
            throw "Connection to $SmtpServer`:$Port timed out after $TimeoutSeconds s."
        }
        $client.EndConnect($iar)
        Write-Smtp I "Connected to $SmtpServer`:$Port"
        $stream = $client.GetStream()
        $stream.ReadTimeout = $TimeoutSeconds * 1000; $stream.WriteTimeout = $TimeoutSeconds * 1000

        if ($Encryption -eq 'Ssl') { $stream = Get-TlsStream $stream $SmtpServer $SkipCertificateCheck }
        Assert-Smtp (Read-SmtpResponse $stream) 220 'greeting'
        Send-SmtpLine $stream "EHLO $localFqdn"
        $ehlo = Read-SmtpResponse $stream; Assert-Smtp $ehlo 250 'EHLO'

        if ($Encryption -eq 'StartTls') {
            if ($ehlo.Text -notmatch '(?im)^\d{3}[ -]STARTTLS') {
                throw "Server did not advertise STARTTLS on $SmtpServer`:$Port. Wrong port for TLS? (587 for STARTTLS, 465 for implicit SSL.)"
            }
            Send-SmtpLine $stream "STARTTLS"; Assert-Smtp (Read-SmtpResponse $stream) 220 'STARTTLS'
            $stream = Get-TlsStream $stream $SmtpServer $SkipCertificateCheck
            Send-SmtpLine $stream "EHLO $localFqdn"
            $ehlo = Read-SmtpResponse $stream; Assert-Smtp $ehlo 250 'EHLO(TLS)'
        }
        if ($Authenticate) {
            if ($ehlo.Text -notmatch '(?im)AUTH.*LOGIN') { Write-Smtp I "Note: server did not advertise AUTH LOGIN - authentication may be disabled here." }
            Send-SmtpLine $stream "AUTH LOGIN"; Assert-Smtp (Read-SmtpResponse $stream) 334 'AUTH LOGIN'
            Send-SmtpLine $stream ([Convert]::ToBase64String([System.Text.Encoding]::ASCII.GetBytes($Credential.UserName))) -Secret
            Assert-Smtp (Read-SmtpResponse $stream) 334 'AUTH username'
            Send-SmtpLine $stream ([Convert]::ToBase64String([System.Text.Encoding]::ASCII.GetBytes($Credential.GetNetworkCredential().Password))) -Secret
            Assert-Smtp (Read-SmtpResponse $stream) 235 'AUTH password'
        }
        Send-SmtpLine $stream "MAIL FROM:<$From>"; Assert-Smtp (Read-SmtpResponse $stream) 250 'MAIL FROM'
        foreach ($rcpt in $To) {
            Send-SmtpLine $stream "RCPT TO:<$rcpt>"; Assert-Smtp (Read-SmtpResponse $stream) @(250,251) "RCPT TO $rcpt"
        }
        Send-SmtpLine $stream "DATA"; Assert-Smtp (Read-SmtpResponse $stream) 354 'DATA'
        $message = New-MimeMessage $From $To $Subject $Body $attachment
        $stuffed = ($message -split "`r?`n" | ForEach-Object { if ($_.StartsWith('.')) { '.' + $_ } else { $_ } }) -join "`r`n"
        $dataBytes = [System.Text.Encoding]::UTF8.GetBytes($stuffed + "`r`n.`r`n")
        $stream.Write($dataBytes, 0, $dataBytes.Length); $stream.Flush()
        Write-Smtp C "[message body: $($dataBytes.Length) bytes] ."
        Assert-Smtp (Read-SmtpResponse $stream) 250 'end-of-DATA'
        Send-SmtpLine $stream "QUIT"; Read-SmtpResponse $stream | Out-Null
        $ok = $true
    } catch {
        $errMsg = $_.Exception.Message; Write-Smtp E $errMsg
    } finally {
        if ($stream) { $stream.Dispose() }; if ($client) { $client.Close() }
    }
    [pscustomobject]@{ Success = $ok; Error = $errMsg; Transcript = $script:Transcript.ToArray() }
}

# =============================================================================
#  Provider presets
# =============================================================================
$providers = [ordered]@{
    'Microsoft 365'          = @{ Server = 'smtp.office365.com';                  Port = 587; Enc = 'StartTls'; Auth = $true;  Note = 'Licensed mailbox login. SMTP AUTH must be enabled on the mailbox. From must match the mailbox.' }
    'M365 High Volume Email' = @{ Server = 'smtp-hve.office365.com';              Port = 587; Enc = 'StartTls'; Auth = $true;  Note = 'For high-volume internal app/device mail. Sign in with a High Volume Email account.' }
    'SendGrid'               = @{ Server = 'smtp.sendgrid.net';                   Port = 587; Enc = 'StartTls'; Auth = $true;  User = 'apikey'; Note = 'Username is literally "apikey"; password is your API key.' }
    'Amazon SES'             = @{ Server = 'email-smtp.us-east-1.amazonaws.com';  Port = 587; Enc = 'StartTls'; Auth = $true;  Note = 'Edit the region in the host. Use SES SMTP credentials (not your AWS access keys).' }
    'Postmark'               = @{ Server = 'smtp.postmarkapp.com';               Port = 587; Enc = 'StartTls'; Auth = $true;  Note = 'Username and password are both your Server API token.' }
    'Mailgun'                = @{ Server = 'smtp.mailgun.org';                    Port = 587; Enc = 'StartTls'; Auth = $true;  Note = 'Use the SMTP credentials from your Mailgun sending domain.' }
    'SMTP2GO'                = @{ Server = 'mail.smtp2go.com';                    Port = 587; Enc = 'StartTls'; Auth = $true;  Note = 'STARTTLS ports 587/2525/8025/25, or SSL on 465/8465.' }
    'Brevo'                  = @{ Server = 'smtp-relay.brevo.com';               Port = 587; Enc = 'StartTls'; Auth = $true;  Note = 'Formerly Sendinblue. Use your account SMTP key.' }
    'Gmail / Workspace'      = @{ Server = 'smtp.gmail.com';                      Port = 587; Enc = 'StartTls'; Auth = $true;  Note = 'Use an app password (requires 2-step verification).' }
    'Custom / Lookup MX'     = @{ Server = '';                                   Port = 25;  Enc = 'None';     Auth = $false; Note = 'Enter a host manually, or use Lookup MX for direct send to a domain''s mail servers.' }
}
$encIndex = @{ None = 0; StartTls = 1; Ssl = 2 }
$script:LastPresetUser = $null   # tracks a username auto-filled by a preset (e.g. SendGrid's "apikey")

# =============================================================================
#  UI
# =============================================================================
$xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="SMTP Diagnostics and Testing Tool" Height="820" Width="980"
        MinHeight="680" MinWidth="820" WindowStartupLocation="CenterScreen"
        Background="#F3F4F6" FontFamily="Segoe UI" FontSize="13">
  <Window.Resources>
    <Style TargetType="TextBox">
      <Setter Property="Height" Value="32"/><Setter Property="Padding" Value="8,5"/>
      <Setter Property="VerticalContentAlignment" Value="Center"/>
      <Setter Property="BorderBrush" Value="#D1D5DB"/><Setter Property="BorderThickness" Value="1"/>
    </Style>
    <Style TargetType="PasswordBox">
      <Setter Property="Height" Value="32"/><Setter Property="Padding" Value="8,5"/>
      <Setter Property="VerticalContentAlignment" Value="Center"/>
      <Setter Property="BorderBrush" Value="#D1D5DB"/><Setter Property="BorderThickness" Value="1"/>
    </Style>
    <Style TargetType="ComboBox">
      <Setter Property="Height" Value="32"/><Setter Property="Padding" Value="8,3"/>
      <Setter Property="VerticalContentAlignment" Value="Center"/>
    </Style>
    <Style x:Key="Lbl" TargetType="TextBlock">
      <Setter Property="VerticalAlignment" Value="Center"/>
      <Setter Property="Foreground" Value="#374151"/><Setter Property="Margin" Value="0,0,12,0"/>
    </Style>
    <Style x:Key="Accent" TargetType="Button">
      <Setter Property="Background" Value="#2563EB"/><Setter Property="Foreground" Value="White"/>
      <Setter Property="FontWeight" Value="SemiBold"/><Setter Property="Padding" Value="22,9"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Template"><Setter.Value>
        <ControlTemplate TargetType="Button">
          <Border x:Name="b" Background="{TemplateBinding Background}" CornerRadius="6" Padding="{TemplateBinding Padding}">
            <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
          </Border>
          <ControlTemplate.Triggers>
            <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="b" Property="Background" Value="#1D4ED8"/></Trigger>
            <Trigger Property="IsEnabled" Value="False"><Setter TargetName="b" Property="Background" Value="#93C5FD"/></Trigger>
          </ControlTemplate.Triggers>
        </ControlTemplate>
      </Setter.Value></Setter>
    </Style>
    <Style x:Key="Ghost" TargetType="Button">
      <Setter Property="Background" Value="#FFFFFF"/><Setter Property="Foreground" Value="#2563EB"/>
      <Setter Property="Padding" Value="14,7"/><Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Template"><Setter.Value>
        <ControlTemplate TargetType="Button">
          <Border x:Name="b" Background="{TemplateBinding Background}" BorderBrush="#2563EB" BorderThickness="1" CornerRadius="6" Padding="{TemplateBinding Padding}">
            <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
          </Border>
          <ControlTemplate.Triggers>
            <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="b" Property="Background" Value="#EFF6FF"/></Trigger>
          </ControlTemplate.Triggers>
        </ControlTemplate>
      </Setter.Value></Setter>
    </Style>
  </Window.Resources>

  <Grid>
    <Grid.RowDefinitions>
      <RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="8"/><RowDefinition Height="*"/>
    </Grid.RowDefinitions>

    <Border Grid.Row="0" Background="#111827" Padding="20,16">
      <StackPanel>
        <TextBlock Text="SMTP Diagnostics and Testing Tool" Foreground="White" FontSize="17" FontWeight="SemiBold"/>
        <TextBlock Text="Submit a test message to any SMTP provider and read the full server conversation." Foreground="#9CA3AF" FontSize="12" Margin="0,2,0,0"/>
      </StackPanel>
    </Border>

    <Border Grid.Row="1" Background="White" CornerRadius="10" BorderBrush="#E5E7EB" BorderThickness="1" Margin="16,16,16,8" Padding="18">
      <StackPanel>
        <Border BorderBrush="#E5E7EB" BorderThickness="1" CornerRadius="8" Padding="12" Margin="0,0,0,12">
          <Grid>
            <Grid.ColumnDefinitions><ColumnDefinition Width="150"/><ColumnDefinition Width="250"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
            <TextBlock Style="{StaticResource Lbl}" Text="SMTP provider"/>
            <ComboBox x:Name="CboProvider" Grid.Column="1"/>
            <TextBlock x:Name="LblProvider" Grid.Column="2" Foreground="#6B7280" FontSize="12" TextWrapping="Wrap" VerticalAlignment="Center" Margin="16,0,0,0"/>
          </Grid>
        </Border>

        <Grid Margin="0,0,0,10">
          <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="16"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
          <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="32"/></Grid.RowDefinitions>
          <TextBlock Text="From (sender address)" Foreground="#374151" Margin="0,0,0,4"/>
          <TextBox x:Name="TxtFrom" Grid.Row="1"/>
          <TextBlock Grid.Column="2" Text="To (recipient)" Foreground="#374151" Margin="0,0,0,4"/>
          <TextBox x:Name="TxtTo" Grid.Row="1" Grid.Column="2"/>
        </Grid>
        <Grid Margin="0,0,0,10">
          <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="16"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
          <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="32"/></Grid.RowDefinitions>
          <TextBlock Text="SMTP Server Address" Foreground="#374151" Margin="0,0,0,4"/>
          <DockPanel Grid.Row="1">
            <Button x:Name="BtnMx" Style="{StaticResource Ghost}" Content="Lookup MX" DockPanel.Dock="Right" Margin="8,0,0,0"/>
            <TextBox x:Name="TxtServer"/>
          </DockPanel>
          <TextBlock Grid.Column="2" Text="SSL/TLS Settings" Foreground="#374151" Margin="0,0,0,4"/>
          <Grid Grid.Row="1" Grid.Column="2">
            <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/><ColumnDefinition Width="72"/></Grid.ColumnDefinitions>
            <ComboBox x:Name="CboEnc">
              <ComboBoxItem>None</ComboBoxItem>
              <ComboBoxItem IsSelected="True">StartTls</ComboBoxItem>
              <ComboBoxItem>Ssl</ComboBoxItem>
            </ComboBox>
            <TextBlock Style="{StaticResource Lbl}" Grid.Column="1" Text="Port" Margin="12,0,8,0"/>
            <TextBox x:Name="TxtPort" Grid.Column="2" Text="587"/>
          </Grid>
        </Grid>

        <CheckBox x:Name="ChkAuth" Content="SMTP Authentication" IsChecked="True" Margin="0,4,0,8" FontWeight="SemiBold"/>
        <StackPanel x:Name="AuthPanel">
          <Grid Margin="0,0,0,10">
            <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="16"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
            <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="32"/></Grid.RowDefinitions>
            <TextBlock Text="User ID" Foreground="#374151" Margin="0,0,0,4"/>
            <TextBox x:Name="TxtUser" Grid.Row="1"/>
            <TextBlock Grid.Column="2" Text="Password" Foreground="#374151" Margin="0,0,0,4"/>
            <PasswordBox x:Name="PwdPass" Grid.Row="1" Grid.Column="2"/>
          </Grid>
        </StackPanel>

        <StackPanel Orientation="Horizontal" Margin="0,2,0,10">
          <CheckBox x:Name="ChkCert" Content="Skip certificate check" IsChecked="True" Margin="0,0,24,0"/>
          <CheckBox x:Name="ChkScan" Content="Attach a test file" IsChecked="True" Margin="0,0,24,0"/>
          <TextBlock Style="{StaticResource Lbl}" Text="Timeout (s)"/>
          <TextBox x:Name="TxtTimeout" Width="60" Text="30"/>
        </StackPanel>

        <StackPanel Orientation="Horizontal">
          <Button x:Name="BtnSend" Style="{StaticResource Accent}" Content="Send Test"/>
          <TextBlock x:Name="LblResult" VerticalAlignment="Center" Margin="16,0,0,0" TextWrapping="Wrap"/>
        </StackPanel>
      </StackPanel>
    </Border>

    <GridSplitter Grid.Row="2" Height="8" HorizontalAlignment="Stretch" Background="Transparent" ResizeDirection="Rows" ResizeBehavior="PreviousAndNext"/>
    <Border Grid.Row="3" Background="#0B1020" CornerRadius="10" Margin="16,8,16,16" MinHeight="180">
      <RichTextBox x:Name="RtbLog" Background="Transparent" Foreground="#E5E7EB" BorderThickness="0"
                   IsReadOnly="True" FontFamily="Consolas" FontSize="12.5" Padding="12"
                   VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Auto"/>
    </Border>
  </Grid>
</Window>
'@

$reader = New-Object System.Xml.XmlNodeReader ([xml]$xaml)
$win = [Windows.Markup.XamlReader]::Load($reader)

$ctl = @{}
'TxtFrom','TxtTo','TxtServer','BtnMx','CboEnc','CboProvider','TxtPort','ChkAuth','AuthPanel','TxtUser','PwdPass','ChkCert','ChkScan','TxtTimeout','BtnSend','LblResult','RtbLog','LblProvider' |
    ForEach-Object { $ctl[$_] = $win.FindName($_) }

function Set-Transcript {
    param([string[]]$Lines)
    $doc = New-Object System.Windows.Documents.FlowDocument
    $doc.PageWidth = 1600; $doc.FontFamily = New-Object System.Windows.Media.FontFamily('Consolas')
    $conv = New-Object System.Windows.Media.BrushConverter
    foreach ($line in $Lines) {
        $hex = switch -Regex ($line) {
            '^C:'   { '#93C5FD'; break }
            '^S:'   { '#A7F3D0'; break }
            '^!!'   { '#FCA5A5'; break }
            default { '#9CA3AF' }
        }
        $p = New-Object System.Windows.Documents.Paragraph
        $p.Margin = New-Object System.Windows.Thickness(0)
        $r = New-Object System.Windows.Documents.Run($line)
        $r.Foreground = $conv.ConvertFromString($hex)
        $p.Inlines.Add($r); $doc.Blocks.Add($p)
    }
    $ctl.RtbLog.Document = $doc
}

function Sync-AuthState {
    $on = [bool]$ctl.ChkAuth.IsChecked
    $ctl.AuthPanel.Visibility = if ($on) { 'Visible' } else { 'Collapsed' }
}

function Set-Provider {
    param([string]$Name)
    $p = $providers[$Name]
    if ($Name -ne 'Custom / Lookup MX') { $ctl.TxtServer.Text = $p.Server }
    $ctl.TxtPort.Text = "$($p.Port)"
    $ctl.CboEnc.SelectedIndex = $encIndex[$p.Enc]
    $ctl.ChkAuth.IsChecked = [bool]$p.Auth
    if ($p.ContainsKey('User')) {
        $ctl.TxtUser.Text = $p.User
        $script:LastPresetUser = $p.User
    } elseif ($ctl.TxtUser.Text -eq $script:LastPresetUser) {
        # Clear a username a previous preset auto-filled (so SendGrid's "apikey" does
        # not linger when you switch to M365/HVE), but keep anything you typed yourself.
        $ctl.TxtUser.Text = ''
        $script:LastPresetUser = $null
    }
    $ctl.LblProvider.Text = $p.Note
    Sync-AuthState
}

# Build the provider dropdown.
foreach ($name in $providers.Keys) {
    [void]$ctl.CboProvider.Items.Add($name)
}
$ctl.CboProvider.Add_SelectionChanged({
    if ($ctl.CboProvider.SelectedItem) { Set-Provider ([string]$ctl.CboProvider.SelectedItem) }
})
$ctl.CboProvider.SelectedItem = 'Microsoft 365' # default

$ctl.ChkAuth.Add_Click({ Sync-AuthState })

$ctl.BtnMx.Add_Click({
    $from = $ctl.TxtFrom.Text.Trim()
    if ($from -notmatch '@') { [void][System.Windows.MessageBox]::Show('Enter the From address first (name@domain).','MX lookup','OK','Information'); return }
    $domain = ($from -split '@')[-1]
    $ctl.BtnMx.IsEnabled = $false; $ctl.BtnMx.Content = '...'
    $mx = Get-MxHosts -Domain $domain
    $ctl.BtnMx.IsEnabled = $true; $ctl.BtnMx.Content = 'Lookup MX'
    if ($mx) {
        $top = $mx[0].Host; $ctl.TxtServer.Text = $top
        if ($ctl.ChkAuth.IsChecked -and $top -match 'mail\.protection\.outlook\.com$') {
            [void][System.Windows.MessageBox]::Show("The MX host ($top) does not accept authentication.`nFor Microsoft 365 authenticated submission use smtp.office365.com:587. An MX host is for no-auth direct send only.",'Heads up','OK','Warning')
        }
    } else {
        [void][System.Windows.MessageBox]::Show("No MX record found for $domain (or DNS unavailable).",'MX lookup','OK','Warning')
    }
})

$ctl.BtnSend.Add_Click({
    $from = $ctl.TxtFrom.Text.Trim()
    $recips = ($ctl.TxtTo.Text -split '[;,]' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    $server = $ctl.TxtServer.Text.Trim()
    if (-not $from -or -not $recips -or -not $server) {
        [void][System.Windows.MessageBox]::Show('From, To, and SMTP Server are required.','Missing fields','OK','Warning'); return
    }
    $port = 0
    if (-not [int]::TryParse($ctl.TxtPort.Text.Trim(), [ref]$port) -or $port -lt 1 -or $port -gt 65535) {
        [void][System.Windows.MessageBox]::Show('Port must be 1-65535.','Invalid port','OK','Warning'); return
    }
    $timeout = 30; [void][int]::TryParse($ctl.TxtTimeout.Text.Trim(), [ref]$timeout)
    $encName = [string]$ctl.CboEnc.SelectedItem.Content

    $auth = [bool]$ctl.ChkAuth.IsChecked
    $cred = $null
    if ($auth) {
        $user = if ($ctl.TxtUser.Text.Trim()) { $ctl.TxtUser.Text.Trim() } else { $from }
        $sec = New-Object System.Security.SecureString
        foreach ($c in $ctl.PwdPass.Password.ToCharArray()) { $sec.AppendChar($c) }
        $sec.MakeReadOnly()
        $cred = New-Object System.Management.Automation.PSCredential($user, $sec)
    }

    $ctl.BtnSend.IsEnabled = $false; $ctl.BtnSend.Content = 'Testing...'; $ctl.LblResult.Text = ''
    $win.Dispatcher.Invoke([action]{}, 'Background')
    try {
        $result = Invoke-SmtpTest -From $from -To $recips -SmtpServer $server -Authenticate $auth `
            -Port $port -Encryption $encName -Credential $cred `
            -Subject "SMTP test - $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')" `
            -Body "Test message from the SMTP Diagnostics and Testing Tool." `
            -Attach ([bool]$ctl.ChkScan.IsChecked) -SkipCertificateCheck ([bool]$ctl.ChkCert.IsChecked) `
            -TimeoutSeconds $timeout
    } catch {
        $result = [pscustomobject]@{ Success = $false; Error = $_.Exception.Message; Transcript = @("!! $($_.Exception.Message)") }
    } finally {
        $ctl.BtnSend.IsEnabled = $true; $ctl.BtnSend.Content = 'Send Test'
    }

    Set-Transcript $result.Transcript
    if ($result.Success) {
        $ctl.LblResult.Text = 'ACCEPTED (250) - if it never arrives, check the provider''s delivery logs and the recipient''s spam folder.'
        $ctl.LblResult.Foreground = 'SeaGreen'
    } else {
        $hint = switch -Regex ($result.Error) {
            '504'        { ' (server has no SMTP AUTH - do not authenticate against an MX/relay host)' ; break }
            '535'        { ' (auth failed - wrong credentials, auth disabled, or MFA needs an app password/API key)' ; break }
            '550|5\.7\.' { ' (relay/policy denied - recipient not allowed, sender not authorized, or SPF/spoof block)' ; break }
            'STARTTLS'   { ' (TLS mismatch - 587 STARTTLS, 465 SSL, or a plain port with None)' ; break }
            'timed out'  { ' (port blocked by firewall/ISP, or wrong host)' ; break }
            default      { '' }
        }
        $ctl.LblResult.Text = "FAILED - $($result.Error)$hint"
        $ctl.LblResult.Foreground = 'Firebrick'
    }
})

[void]$win.ShowDialog()
