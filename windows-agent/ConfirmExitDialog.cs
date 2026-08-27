using System.Drawing;
using System.Windows.Forms;

namespace RemKeysAgent;

/// <summary>
/// The confirmation behind the tray's Exit item: stopping the agent is asked
/// for by typing the word, not by pressing a default button.
///
/// The friction is the point. Exit sits at the bottom of a menu a screen-reader
/// user arrows through, and what it costs is invisible — the agent is
/// windowless, so a mis-triggered Exit looks like nothing happening at all
/// until a keystroke from the phone silently fails to arrive, and it stays that
/// way until the next sign-in (or, with lock screen support on, the next
/// reboot). No stray Enter can produce the word "exit" in an empty box.
///
/// Accessibility notes, since this is the one dialog in the app that is not a
/// plain MessageBox:
/// <list type="bullet">
/// <item>It is a real dialog (<c>FixedDialog</c>, no minimize/maximize), which
/// is what makes a screen reader read the whole body when it opens — the same
/// thing a MessageBox gets for free.</item>
/// <item>The prompt is a Label immediately before the text box, which is how
/// WinForms gives the box its accessible name; it is also set outright.</item>
/// <item>The Stop button is deliberately NOT disabled-until-valid. A disabled
/// WinForms button is skipped in the tab order entirely, so a typo would leave
/// a blind user pressing Enter at a dialog that answers nothing. Pressing it
/// with the wrong text says so in a MessageBox instead, which is spoken.</item>
/// <item>It is in the taskbar and topmost: the agent has no window of its own,
/// so a dialog that slipped behind something else could not be found again.</item>
/// </list>
/// </summary>
internal static class ConfirmExitDialog
{
    /// <summary>Compared trimmed and case-insensitively — "EXIT " is a yes.</summary>
    private const string RequiredWord = "exit";

    /// <summary>
    /// Ask, and report whether the agent should stop. Runs on the caller's
    /// thread, which is the tray icon's own STA thread — the menu is already
    /// gone by the time this appears.
    /// </summary>
    /// <param name="consequence">
    /// What stopping costs and how to get it back, which differs by mode; see
    /// <see cref="ITrayHost.ExitConsequence"/>.
    /// </param>
    public static bool Confirmed(string consequence)
    {
        const int TextWidth = 440;

        using var form = new Form
        {
            Text = "Stop the RemKeys agent",
            FormBorderStyle = FormBorderStyle.FixedDialog,
            StartPosition = FormStartPosition.CenterScreen,
            MinimizeBox = false,
            MaximizeBox = false,
            ShowIcon = false,
            ShowInTaskbar = true,
            TopMost = true,
            AutoSize = true,
            AutoSizeMode = AutoSizeMode.GrowAndShrink,
            // Match the MessageBoxes this dialog sits among, rather than
            // WinForms' smaller default.
            Font = SystemFonts.MessageBoxFont ?? SystemFonts.DefaultFont,
        };

        var layout = new TableLayoutPanel
        {
            ColumnCount = 1,
            AutoSize = true,
            AutoSizeMode = AutoSizeMode.GrowAndShrink,
            Dock = DockStyle.Fill,
            Padding = new Padding(16),
        };

        var message = new Label
        {
            Text = "Stop the RemKeys agent?\r\n\r\n" + consequence,
            AutoSize = true,
            MaximumSize = new Size(TextWidth, 0),
            UseMnemonic = false, // an "&" in the text is text, not a shortcut
            Margin = new Padding(0, 0, 0, 16),
            TabIndex = 0,
        };

        var prompt = new Label
        {
            Text = $"Type {RequiredWord} and press Enter to confirm:",
            AutoSize = true,
            MaximumSize = new Size(TextWidth, 0),
            UseMnemonic = false,
            Margin = new Padding(0, 0, 0, 4),
            TabIndex = 1,
        };

        var entry = new TextBox
        {
            Width = TextWidth,
            TabIndex = 2,
            // Belt to the preceding label's braces: WinForms derives a text
            // box's accessible name from the label before it, but saying it
            // outright costs nothing and cannot drift.
            AccessibleName = prompt.Text,
        };

        var stop = new Button { Text = "Stop agent", AutoSize = true, TabIndex = 3 };
        var cancel = new Button
        {
            Text = "Cancel",
            DialogResult = DialogResult.Cancel,
            AutoSize = true,
            TabIndex = 4,
        };

        var buttons = new FlowLayoutPanel
        {
            // Right to left, so the first one added ends up rightmost: Cancel
            // on the right, Stop to its left, the way Windows dialogs read.
            FlowDirection = FlowDirection.RightToLeft,
            AutoSize = true,
            AutoSizeMode = AutoSizeMode.GrowAndShrink,
            Anchor = AnchorStyles.Right,
            Margin = new Padding(0, 16, 0, 0),
        };
        buttons.Controls.Add(cancel);
        buttons.Controls.Add(stop);

        layout.Controls.Add(message);
        layout.Controls.Add(prompt);
        layout.Controls.Add(entry);
        layout.Controls.Add(buttons);
        form.Controls.Add(layout);

        // Enter submits and Escape cancels. Note that Enter only ever
        // *submits* — whether it stops anything is decided by what is in the
        // box, which is what makes a stray keypress harmless.
        form.AcceptButton = stop;
        form.CancelButton = cancel;

        stop.Click += (_, _) =>
        {
            if (string.Equals(entry.Text.Trim(), RequiredWord, StringComparison.OrdinalIgnoreCase))
            {
                form.DialogResult = DialogResult.OK; // closes the modal form
                return;
            }

            // Spoken feedback on the typo path. Without it, Enter at a
            // half-typed box would do nothing at all and say nothing either.
            MessageBox.Show(form,
                $"Type the word {RequiredWord} into the box to stop the agent, " +
                "or choose Cancel to leave it running.",
                "RemKeys", MessageBoxButtons.OK, MessageBoxIcon.Information);
            entry.Focus();
            entry.SelectAll();
        };

        form.Shown += (_, _) =>
        {
            form.Activate();
            entry.Focus();
        };

        return form.ShowDialog() == DialogResult.OK;
    }
}
