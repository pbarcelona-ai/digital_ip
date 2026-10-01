(() => {
  const config = document.currentScript;
  if (!config) return;

  const manifestUrl = new URL(config.dataset.downloadManifest, document.baseURI);
  const status = document.querySelector("[data-download-status]");
  const moduleButtons = [...document.querySelectorAll("[data-download-ip]")];
  const selectedButton = document.querySelector("[data-download-selected]");
  const selectAll = document.querySelector("[data-select-all]");
  const selections = [...document.querySelectorAll("[data-ip-select]")];
  const fileCache = new Map();
  let manifest;
  let busy = false;

  function updateSelection() {
    if (!selectedButton) return;
    const selected = selections.filter((input) => input.checked);
    selectedButton.textContent = `Download selected (${selected.length})`;
    selectedButton.disabled = busy || !manifest || selected.length === 0;
    if (selectAll) {
      selectAll.checked = selections.length > 0 && selected.length === selections.length;
      selectAll.indeterminate = selected.length > 0 && selected.length < selections.length;
    }
  }

  async function fetchFile(path) {
    if (!fileCache.has(path)) {
      const encodedPath = path.split("/").map(encodeURIComponent).join("/");
      const sourceUrl = new URL(encodedPath, manifest.sourceBase).href;
      fileCache.set(path, fetch(sourceUrl).then((response) => {
        if (!response.ok) throw new Error(`Unable to fetch ${path} (${response.status})`);
        return response.arrayBuffer();
      }));
    }
    return fileCache.get(path);
  }

  function readme(module) {
    const scalerNote = module.category === "scalers"
      ? "Scaler synthesis scripts require Bash 4 or newer; macOS's built-in Bash 3.2 is not sufficient.\n\n"
      : "";
    return `# ${module.name} standalone IP bundle\n\n` +
      "This archive includes this IP, manifest-listed RTL and testbench dependencies, shared source/support files, and project runners. Generated build outputs are omitted.\n\n" +
      `Top module: \`${module.top}\`\n\n` + scalerNote +
      "Configure `.tools` if needed, then run from this directory:\n\n" +
      `\`\`\`sh\nmake test IP=${module.name}\nmake synth IP=${module.name}\n\`\`\`\n\n` +
      "Install the selected simulator and synthesis tools separately. Python test dependencies are listed in `requirements-python-test.txt`.\n";
  }

  async function createArchive(names) {
    if (!manifest || busy || names.length === 0) return;
    busy = true;
    if (status) status.textContent = `Preparing ${names.length} IP${names.length === 1 ? "" : "s"}...`;
    moduleButtons.forEach((button) => { button.disabled = true; });
    updateSelection();

    try {
      const zip = new JSZip();
      const items = [];
      for (const name of names) {
        const module = manifest.modules[name];
        if (!module) throw new Error(`No download manifest for ${name}`);
        const prefix = `digital_ip_${name}`;
        for (const file of [...manifest.common_files, ...module.files]) {
          items.push({
            source: file.path,
            target: `${prefix}/${file.path}`,
            executable: file.executable,
          });
        }
        zip.file(`${prefix}/DOWNLOAD_README.md`, readme({ ...module, name }));
      }

      let next = 0;
      let completed = 0;
      const worker = async () => {
        while (next < items.length) {
          const item = items[next++];
          const contents = await fetchFile(item.source);
          zip.file(item.target, contents, {
            binary: true,
            unixPermissions: item.executable ? 0o100755 : 0o100644,
          });
          completed++;
          if (completed % 25 === 0 || completed === items.length) {
            if (status) status.textContent = `Collecting files: ${completed} of ${items.length}`;
          }
        }
      };
      await Promise.all(Array.from({ length: Math.min(8, items.length) }, worker));
      if (status) status.textContent = "Compressing download...";
      const blob = await zip.generateAsync(
        { type: "blob", compression: "DEFLATE", compressionOptions: { level: 6 } },
        (progress) => {
          if (status) status.textContent = `Compressing download: ${Math.round(progress.percent)}%`;
        },
      );
      const url = URL.createObjectURL(blob);
      const link = document.createElement("a");
      link.href = url;
      link.download = names.length === 1 ? `digital_ip_${names[0]}.zip` : `digital_ip_selected_${names.length}.zip`;
      document.body.append(link);
      link.click();
      link.remove();
      setTimeout(() => URL.revokeObjectURL(url), 60_000);
      if (status) status.textContent = `Download ready: ${link.download}`;
    } catch (error) {
      if (status) status.textContent = `Download failed: ${error.message}`;
    } finally {
      busy = false;
      moduleButtons.forEach((button) => { button.disabled = !manifest; });
      updateSelection();
    }
  }

  moduleButtons.forEach((button) => {
    button.addEventListener("click", () => createArchive([button.dataset.downloadIp]));
  });
  selections.forEach((input) => input.addEventListener("change", updateSelection));
  if (selectAll) {
    selectAll.addEventListener("change", () => {
      selections.forEach((input) => { input.checked = selectAll.checked; });
      updateSelection();
    });
  }
  if (selectedButton) {
    selectedButton.addEventListener("click", () => {
      createArchive(selections.filter((input) => input.checked).map((input) => input.value));
    });
  }

  fetch(manifestUrl)
    .then((response) => {
      if (!response.ok) throw new Error(`Download manifest unavailable (${response.status})`);
      return response.json();
    })
    .then((data) => {
      if (typeof JSZip === "undefined") throw new Error("ZIP library unavailable");
      manifest = { ...data, sourceBase: new URL(data.base_url, manifestUrl) };
      moduleButtons.forEach((button) => { button.disabled = false; });
      updateSelection();
      if (status) status.textContent = "Downloads ready.";
    })
    .catch((error) => {
      if (status) status.textContent = `Downloads unavailable: ${error.message}`;
    });
})();
