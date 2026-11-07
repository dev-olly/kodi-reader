const tabs = Array.from(document.querySelectorAll('[role="tab"]'));
document.querySelectorAll('[data-question]').forEach(button => {
  button.addEventListener('click', () => {
    document.querySelectorAll('[data-question]').forEach(item => item.setAttribute('aria-pressed', String(item === button)));
    document.getElementById('sample-answer').textContent = button.dataset.question === 'practice'
      ? 'After a chapter, pause. Pick one sentence, write what it means to you, and notice where that idea appears during your day.'
      : 'The author invites us to slow down. Stay with one idea long enough to notice what it means to you.';
    document.querySelector('.sample-question').textContent = button.dataset.question === 'practice' ? 'How can I put this into practice?' : 'What does “look a little longer” mean?';
  });
});
document.getElementById('sample-note').addEventListener('input', () => {
  document.getElementById('note-status').textContent = 'Edited in this preview';
});
const sketch = document.getElementById('sample-canvas');
const context = sketch.getContext('2d');
let drawing = false;
new ResizeObserver(() => {
  const bounds = sketch.getBoundingClientRect();
  if (!bounds.width || !bounds.height) return;
  const width = Math.round(bounds.width * devicePixelRatio);
  const height = Math.round(bounds.height * devicePixelRatio);
  if (sketch.width === width && sketch.height === height) return;
  sketch.width = width;
  sketch.height = height;
  context.scale(devicePixelRatio, devicePixelRatio);
  context.strokeStyle = '#42694f';
  context.lineWidth = 2;
  context.lineCap = 'round';
}).observe(sketch);
sketch.addEventListener('pointerdown', event => {
  drawing = true;
  sketch.setPointerCapture(event.pointerId);
  context.beginPath();
  context.moveTo(event.offsetX, event.offsetY);
});
sketch.addEventListener('pointermove', event => {
  if (!drawing) return;
  context.lineTo(event.offsetX, event.offsetY);
  context.stroke();
});
['pointerup', 'pointercancel', 'lostpointercapture'].forEach(name => sketch.addEventListener(name, () => { drawing = false; }));
document.getElementById('clear-sketch').addEventListener('click', () => context.clearRect(0,0,sketch.width,sketch.height));
const demo = document.querySelector('.reader-demo');
document.getElementById('demo-theme').addEventListener('click', (event) => {
  const dark = demo.dataset.theme !== 'dark';
  demo.dataset.theme = dark ? 'dark' : 'light';
  event.currentTarget.setAttribute('aria-pressed', String(dark));
  event.currentTarget.setAttribute('aria-label', `Switch preview to ${dark ? 'light' : 'dark'} theme`);
});
document.querySelectorAll('[data-highlight]').forEach(button => {
  button.addEventListener('click', () => {
    demo.dataset.highlight = button.dataset.highlight;
    document.querySelectorAll('.swatch').forEach(item => item.setAttribute('aria-pressed', String(item === button)));
  });
});
document.querySelectorAll('[data-demo-mode]').forEach(button => {
  button.addEventListener('click', () => {
    document.querySelectorAll('[data-demo-mode]').forEach(item => item.setAttribute('aria-pressed', String(item === button)));
    demoMode = button.dataset.demoMode;
    document.querySelector('.demo-controls').hidden = demoMode === 'ai';
    document.getElementById('demo-response').textContent = button.dataset.demoMode === 'ai'
      ? 'The passage suggests that attention is a practice: staying with an idea long enough to understand it, rather than simply moving on to the next one.'
      : 'Less collecting, more noticing. I want to bring this into how I read, work, and spend my days.';
    document.querySelector('.demo-note-label').textContent = button.dataset.demoMode === 'ai' ? 'A DIFFERENT PERSPECTIVE' : 'A THOUGHT TO KEEP';
    filterDemoMargin();
  });
});
function selectTab(tab) {
  tabs.forEach((item) => {
    const selected = item === tab;
    item.setAttribute("aria-selected", String(selected));
    item.tabIndex = selected ? 0 : -1;
    document.getElementById(item.getAttribute("aria-controls")).hidden = !selected;
  });
}
tabs.forEach((tab, index) => {
  tab.addEventListener("click", () => selectTab(tab));
  tab.addEventListener("keydown", (event) => {
    let next;
    if (event.key === "ArrowRight") next = (index + 1) % tabs.length;
    if (event.key === "ArrowLeft") next = (index + tabs.length - 1) % tabs.length;
    if (event.key === "Home") next = 0;
    if (event.key === "End") next = tabs.length - 1;
    if (next === undefined) return;
    event.preventDefault();
    selectTab(tabs[next]);
    tabs[next].focus();
  });
});

let demoMode = 'note';
function filterDemoMargin() {
  const annotation = document.querySelector('.demo-annotation');
  const query = document.getElementById('demo-search').value.trim().toLocaleLowerCase();
  const chapter = document.getElementById('demo-chapter-filter').value;
  const kind = document.getElementById('demo-filter').value;
  // The preview contains one saved note, from chapter three.
  const matches = demoMode === 'ai' || (
    annotation.textContent.toLocaleLowerCase().includes(query) &&
    (chapter === 'all' || chapter === '3') && kind !== 'highlights'
  );
  annotation.hidden = !matches;
  document.querySelector('.demo-no-matches').hidden = matches;
}
['demo-search', 'demo-filter', 'demo-chapter-filter'].forEach(id => {
  document.getElementById(id).addEventListener(id === 'demo-search' ? 'input' : 'change', filterDemoMargin);
});

// This queue is an ephemeral product demo. It never sends or saves a visitor's text.
const reminderForm = document.getElementById('sample-reminder-form');
const reminderTitle = document.getElementById('sample-reminder-title');
const reminderList = document.getElementById('sample-reminder-list');
const reminderMarker = document.getElementById('demo-reminder-marker');
const reminderStatus = document.getElementById('reminder-demo-status');
const reminderSource = document.getElementById('sample-reminder-source');
const selectedTopic = 'Database sharding';

function showReminderForm({ reset = false } = {}) {
  if (reset) reminderTitle.value = selectedTopic;
  reminderTitle.setCustomValidity('');
  reminderForm.hidden = false;
  reminderMarker.setAttribute('aria-expanded', 'true');
  reminderStatus.textContent = 'Edit the topic, then add it to the demo list.';
  reminderTitle.focus({ preventScroll: true });
  reminderTitle.select();
}

function hideReminderForm() {
  reminderForm.hidden = true;
  reminderMarker.setAttribute('aria-expanded', 'false');
}

function updateReminderCount() {
  const count = reminderList.querySelectorAll('input[type="checkbox"]:not(:checked)').length;
  document.getElementById('reminder-open-count').textContent = `${String(count).padStart(2, '0')} OPEN`;
}

reminderForm.addEventListener('submit', event => {
  event.preventDefault();
  const title = reminderTitle.value.trim();
  if (!title) {
    reminderTitle.setCustomValidity('Add a topic you would like to research.');
    reminderTitle.reportValidity();
    return;
  }
  reminderTitle.setCustomValidity('');
  const item = document.createElement('li');
  item.className = 'research-task';
  const label = document.createElement('label');
  const checkbox = document.createElement('input');
  checkbox.type = 'checkbox';
  const text = document.createElement('span');
  text.textContent = title;
  label.append(checkbox, text);
  const source = document.createElement('a');
  source.href = '#sample-reminder-source';
  source.textContent = 'System Design · Databases ↗';
  source.setAttribute('aria-label', `Return to the source passage for ${title}`);
  item.append(label, source);
  reminderList.append(item);
  updateReminderCount();
  hideReminderForm();
  reminderStatus.textContent = `“${title}” added to this demo. The selected passage stays attached.`;
  checkbox.focus({ preventScroll: true });
});

reminderTitle.addEventListener('input', () => reminderTitle.setCustomValidity(''));
document.getElementById('cancel-reminder-preview').addEventListener('click', () => {
  hideReminderForm();
  reminderTitle.value = selectedTopic;
  reminderStatus.textContent = 'Canceled. No reminder was added.';
  reminderMarker.focus({ preventScroll: true });
});
reminderForm.addEventListener('keydown', event => {
  if (event.key !== 'Escape') return;
  event.preventDefault();
  document.getElementById('cancel-reminder-preview').click();
});
reminderMarker.addEventListener('click', () => {
  if (reminderForm.hidden) showReminderForm({ reset: true });
  else {
    hideReminderForm();
    reminderStatus.textContent = 'The demo list keeps your topics close to their source.';
  }
});
document.getElementById('add-another-reminder').addEventListener('click', () => showReminderForm({ reset: true }));
reminderList.addEventListener('change', event => {
  if (!event.target.matches('input[type="checkbox"]')) return;
  const item = event.target.closest('.research-task');
  item.classList.toggle('is-complete', event.target.checked);
  updateReminderCount();
  const title = item.querySelector('label > span').textContent;
  reminderStatus.textContent = `“${title}” marked ${event.target.checked ? 'complete' : 'open'} in this demo.`;
});
reminderList.addEventListener('click', event => {
  if (!event.target.closest('a')) return;
  reminderSource.classList.remove('is-source-active');
  // Restart the small source cue even when the same link is followed again.
  void reminderSource.offsetWidth;
  reminderSource.classList.add('is-source-active');
  setTimeout(() => reminderSource.classList.remove('is-source-active'), 1200);
});
