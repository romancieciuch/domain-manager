<article class="component-row">
    <?php $statusIcon = ['available' => '✓', 'warning' => '!', 'missing' => '×'][$component['state']] ?? '?'; ?>
    <span class="component-icon <?= e($component['state']) ?>"><?= $statusIcon ?></span>
    <div class="component-copy">
        <strong><?= e($component['name']) ?></strong>
        <small title="<?= e($component['detail']) ?>"><?= e($component['detail']) ?></small>
    </div>
    <?php if ($component['version'] !== null): ?><span class="version-badge"><?= e($component['version']) ?></span><?php endif; ?>
</article>
