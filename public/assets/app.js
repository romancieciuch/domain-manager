const list = document.querySelector('#domain-list');
const addButton = document.querySelector('#add-domain');

function refreshDomainRows() {
    if (!list) return;

    const rows = [...list.querySelectorAll('.domain-row')];
    rows.forEach((row, index) => {
        const radio = row.querySelector('input[type="radio"]');
        radio.value = String(index);
        row.querySelector('.remove-domain').disabled = rows.length === 1;
    });

    if (!list.querySelector('input[type="radio"]:checked') && rows[0]) {
        rows[0].querySelector('input[type="radio"]').checked = true;
    }
}

addButton?.addEventListener('click', () => {
    const row = document.createElement('div');
    row.className = 'domain-row';
    row.innerHTML = `
        <label class="primary-choice" title="Domena główna">
            <input type="radio" name="primary_domain"><span>★</span>
        </label>
        <input name="domains[]" required placeholder="local.futureminingexpo.pl">
        <button class="icon-button remove-domain" type="button" aria-label="Usuń domenę">&minus;</button>`;
    list.append(row);
    refreshDomainRows();
    row.querySelector('input[name="domains[]"]').focus();
});

list?.addEventListener('click', (event) => {
    const button = event.target.closest('.remove-domain');
    if (!button || button.disabled) return;
    button.closest('.domain-row').remove();
    refreshDomainRows();
});

refreshDomainRows();

const projectSearch = document.querySelector('#project-search');
const projectCards = [...document.querySelectorAll('[data-project-card]')];
const searchEmpty = document.querySelector('#search-empty');

projectSearch?.addEventListener('input', () => {
    const query = projectSearch.value.trim().toLocaleLowerCase('pl');
    let visibleCount = 0;

    projectCards.forEach((card) => {
        const visible = card.dataset.search.includes(query);
        card.hidden = !visible;
        if (visible) visibleCount += 1;
    });

    if (searchEmpty) searchEmpty.hidden = visibleCount !== 0;
});

const projectDeleteDialog = document.querySelector('#project-delete-dialog');
const projectDeleteName = projectDeleteDialog?.querySelector('[data-delete-project-name]');
const projectDeleteCancel = projectDeleteDialog?.querySelector('[data-delete-cancel]');
let pendingDeleteForm = null;
let deleteTrigger = null;

document.querySelectorAll('.delete-form').forEach((form) => {
    form.addEventListener('submit', (event) => {
        if (form.dataset.deleteConfirmed === 'true') {
            delete form.dataset.deleteConfirmed;
            return;
        }

        if (!projectDeleteDialog?.showModal) {
            const confirmed = window.confirm(`Usunąć projekt „${form.dataset.projectName}” z Domain Managera?`);
            if (!confirmed) event.preventDefault();
            return;
        }

        event.preventDefault();
        pendingDeleteForm = form;
        deleteTrigger = event.submitter ?? document.activeElement;
        projectDeleteName.textContent = `„${form.dataset.projectName}”`;
        projectDeleteDialog.showModal();
        projectDeleteCancel.focus();
    });
});

projectDeleteDialog?.addEventListener('close', () => {
    const form = pendingDeleteForm;
    const trigger = deleteTrigger;
    pendingDeleteForm = null;
    deleteTrigger = null;

    if (projectDeleteDialog.returnValue === 'confirm' && form) {
        form.dataset.deleteConfirmed = 'true';
        form.requestSubmit();
        return;
    }

    trigger?.focus();
});

projectDeleteDialog?.addEventListener('click', (event) => {
    if (event.target !== projectDeleteDialog) return;

    const bounds = projectDeleteDialog.getBoundingClientRect();
    const inside = event.clientX >= bounds.left && event.clientX <= bounds.right
        && event.clientY >= bounds.top && event.clientY <= bounds.bottom;

    if (!inside) projectDeleteDialog.close('cancel');
});

const clearLogForm = document.querySelector('.clear-log-form');
const logClearDialog = document.querySelector('#log-clear-dialog');
const logClearCancel = logClearDialog?.querySelector('[data-log-clear-cancel]');
let logClearTrigger = null;

clearLogForm?.addEventListener('submit', (event) => {
    if (clearLogForm.dataset.clearConfirmed === 'true') {
        delete clearLogForm.dataset.clearConfirmed;
        return;
    }

    if (!logClearDialog?.showModal) {
        const confirmed = window.confirm('Wyczyścić bieżący dziennik błędów Apache i usunąć jego rotacje?\n\nTej operacji nie można cofnąć.');
        if (!confirmed) event.preventDefault();
        return;
    }

    event.preventDefault();
    logClearTrigger = event.submitter ?? document.activeElement;
    logClearDialog.showModal();
    logClearCancel.focus();
});

logClearDialog?.addEventListener('close', () => {
    const trigger = logClearTrigger;
    logClearTrigger = null;

    if (logClearDialog.returnValue === 'confirm' && clearLogForm) {
        clearLogForm.dataset.clearConfirmed = 'true';
        clearLogForm.requestSubmit();
        return;
    }

    trigger?.focus();
});

logClearDialog?.addEventListener('click', (event) => {
    if (event.target !== logClearDialog) return;

    const bounds = logClearDialog.getBoundingClientRect();
    const inside = event.clientX >= bounds.left && event.clientX <= bounds.right
        && event.clientY >= bounds.top && event.clientY <= bounds.bottom;

    if (!inside) logClearDialog.close('cancel');
});

document.querySelector('#copy-config')?.addEventListener('click', async (event) => {
    const configuration = document.querySelector('#apache-config')?.textContent ?? '';
    await navigator.clipboard.writeText(configuration);
    event.currentTarget.textContent = 'Skopiowano';
    window.setTimeout(() => { event.currentTarget.textContent = 'Kopiuj'; }, 1600);
});

document.querySelectorAll('[data-copy-path]').forEach((button) => {
    button.addEventListener('click', async () => {
        const path = button.dataset.copyPath;
        try {
            if (!navigator.clipboard?.writeText) throw new Error('Clipboard API unavailable');
            await navigator.clipboard.writeText(path);
        } catch {
            const input = document.createElement('textarea');
            input.value = path;
            input.style.position = 'fixed';
            input.style.opacity = '0';
            document.body.append(input);
            input.select();
            document.execCommand('copy');
            input.remove();
        }
        const previousLabel = button.textContent;
        button.textContent = 'Skopiowano';
        window.setTimeout(() => { button.textContent = previousLabel; }, 1400);
    });
});
