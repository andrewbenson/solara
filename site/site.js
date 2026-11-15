const latestReleaseUrl = "https://api.github.com/repos/andrewbenson/solara/releases/latest";

async function pointDownloadsAtLatestDmg() {
  const response = await fetch(latestReleaseUrl, { headers: { Accept: "application/vnd.github+json" } });
  if (!response.ok) return;
  const release = await response.json();
  const dmg = release.assets.find((asset) => asset.name.endsWith(".dmg"));
  if (!dmg) return;
  for (const link of document.querySelectorAll("#download, .dmg-link")) {
    link.href = dmg.browser_download_url;
  }
  const versionLabel = document.getElementById("version");
  if (versionLabel) versionLabel.textContent = `Version ${release.tag_name.replace(/^v/, "")}`;
}

function wireCopyButton() {
  const button = document.getElementById("copy-brew");
  const commandText = document.getElementById("brew");
  if (!button || !commandText) return;
  const command = commandText.textContent;
  button.addEventListener("click", async () => {
    try {
      await navigator.clipboard.writeText(command);
      button.textContent = "Copied";
    } catch {
      button.textContent = "Select and copy";
    }
    setTimeout(() => {
      button.textContent = "Copy";
    }, 2000);
  });
}

wireCopyButton();
pointDownloadsAtLatestDmg().catch(() => {});
