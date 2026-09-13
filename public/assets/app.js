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

document.querySelectorAll('.delete-form').forEach((form) => {
    form.addEventListener('submit', (event) => {
        const projectName = form.dataset.projectName;
        const confirmed = window.confirm(
            `Usunąć projekt „${projectName}” z Domain Managera?\n\nUsuniemy jego domeny, VirtualHost i certyfikat. Katalog i pliki projektu pozostaną bez zmian.`
        );

        if (!confirmed) event.preventDefault();
    });
});

document.querySelector('.clear-log-form')?.addEventListener('submit', (event) => {
    if (!window.confirm('Wyczyścić bieżący dziennik błędów Apache i usunąć jego rotacje?\n\nTej operacji nie można cofnąć.')) {
        event.preventDefault();
    }
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
