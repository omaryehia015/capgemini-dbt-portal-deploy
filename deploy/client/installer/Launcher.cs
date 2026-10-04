// DbtPortalSetup.exe: the app a client downloads and runs. It carries the
// setup window (DbtPortalSetup.ps1, embedded as a resource) and runs it with
// Windows PowerShell, which every supported Windows has. Built by build.ps1.
using System;
using System.Diagnostics;
using System.IO;
using System.Reflection;
using System.Text;
using System.Windows.Forms;

[assembly: AssemblyTitle("dbt Portal Setup")]
[assembly: AssemblyProduct("dbt Portal")]
[assembly: AssemblyDescription("Installs the dbt Portal on this computer")]
[assembly: AssemblyVersion("1.0.0.0")]
[assembly: AssemblyFileVersion("1.0.0.0")]

static class Launcher
{
    [STAThread]
    static int Main()
    {
        string script;
        using (var stream = Assembly.GetExecutingAssembly().GetManifestResourceStream("DbtPortalSetup.ps1"))
        using (var reader = new StreamReader(stream))
        {
            script = reader.ReadToEnd();
        }

        string path = Path.Combine(Path.GetTempPath(), "dbt-portal-setup-" + Guid.NewGuid().ToString("N").Substring(0, 8) + ".ps1");
        try
        {
            // A BOM so Windows PowerShell reads the file as UTF-8.
            File.WriteAllText(path, script, new UTF8Encoding(true));
            var info = new ProcessStartInfo
            {
                FileName = Path.Combine(Environment.SystemDirectory, @"WindowsPowerShell\v1.0\powershell.exe"),
                Arguments = "-NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File \"" + path + "\"",
                UseShellExecute = false,
                CreateNoWindow = true,
            };
            using (var process = Process.Start(info))
            {
                process.WaitForExit();
                return process.ExitCode;
            }
        }
        catch (Exception ex)
        {
            MessageBox.Show("dbt Portal Setup could not start: " + ex.Message, "dbt Portal Setup",
                MessageBoxButtons.OK, MessageBoxIcon.Error);
            return 1;
        }
        finally
        {
            try { File.Delete(path); } catch (IOException) { } catch (UnauthorizedAccessException) { }
        }
    }
}
