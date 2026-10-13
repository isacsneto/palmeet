const $ = (id) => document.getElementById(id);

async function renderStatus() {
  const { status } = await chrome.storage.session.get('status');
  const el = $('status');
  if (status?.connected) {
    el.textContent = `Connected to PalMeet (port ${status.port})`;
    el.className = 'status ok';
  } else {
    el.textContent = 'Not connected';
    el.className = 'status bad';
  }
  $('statusDetail').textContent = status?.message ?? '';
}

async function renderProfile() {
  const { profileLabel, profileInstanceId } = await chrome.storage.local.get(['profileLabel', 'profileInstanceId']);
  $('label').value = profileLabel ?? '';
  $('label').placeholder = profileInstanceId ? `Profile ${profileInstanceId.slice(0, 6)}` : 'e.g. Work';
  $('profileId').textContent = profileInstanceId ?? '(not created yet)';
  $('extId').textContent = chrome.runtime.id;
}

$('save').addEventListener('click', async () => {
  await chrome.storage.local.set({ profileLabel: $('label').value.trim() });
  $('saved').textContent = 'Saved. PalMeet will show the new name.';
});

$('useEmail').addEventListener('click', async () => {
  const granted = await chrome.permissions.request({ permissions: ['identity', 'identity.email'] });
  if (!granted) {
    $('saved').textContent = 'Permission not granted.';
    return;
  }
  try {
    const info = await chrome.identity.getProfileUserInfo({ accountStatus: 'ANY' });
    if (info?.email) {
      $('label').value = info.email;
      await chrome.storage.local.set({ profileLabel: info.email });
      $('saved').textContent = 'Saved.';
    } else {
      $('saved').textContent = 'This profile is not signed in to a Google account.';
    }
  } catch (error) {
    $('saved').textContent = `Could not read the profile email: ${error?.message ?? error}`;
  }
});

$('reconnect').addEventListener('click', async () => {
  await chrome.runtime.sendMessage({ target: 'background', type: 'reconnect' }).catch(() => {});
  setTimeout(renderStatus, 1000);
});

chrome.storage.onChanged.addListener((changes, area) => {
  if (area === 'session' && changes.status) renderStatus();
  if (area === 'local' && changes.profileInstanceId) renderProfile();
});

renderStatus();
renderProfile();
