import { useEffect, type ChangeEvent, type ReactElement } from 'react';
import logo from '@/assets/logo.png';
import { DEFAULT_BRAND_NAME, DEFAULT_BRAND_SETTINGS, brandLabel } from '@/app/storage';
import type { BrandSettings } from '@/app/types';
import { Button, TextField } from '@/shared/ui/UiPrimitives';

function resizeBrandImage(file: File, maxWidth: number, maxHeight: number): Promise<string> {
  return new Promise((resolve, reject) => {
    const image = new Image();
    image.onload = () => {
      const scale = Math.min(1, maxWidth / image.width, maxHeight / image.height);
      const canvas = document.createElement('canvas');
      canvas.width = Math.max(1, Math.round(image.width * scale));
      canvas.height = Math.max(1, Math.round(image.height * scale));
      canvas.getContext('2d')?.drawImage(image, 0, 0, canvas.width, canvas.height);
      URL.revokeObjectURL(image.src);
      resolve(canvas.toDataURL('image/png'));
    };
    image.onerror = () => reject(new Error('Could not read this image.'));
    image.src = URL.createObjectURL(file);
  });
}

export function BrandLockup({ brand }: { brand: BrandSettings }): ReactElement {
  const name = brandLabel(brand);
  const nameChanged = name !== DEFAULT_BRAND_NAME;
  if (brand.logoDataUrl) {
    return (
      <div className="brand-lockup">
        <img className="wordmark" src={brand.logoDataUrl} alt={nameChanged ? '' : name} />
        {nameChanged && <strong className="brand-name">{name}</strong>}
      </div>
    );
  }
  if (nameChanged || brand.iconDataUrl) {
    return (
      <div className="brand-lockup">
        <img className="brand-icon" src={brand.iconDataUrl || '/logo-192.png'} alt="" />
        <strong className="brand-name">{name}</strong>
      </div>
    );
  }
  return <img className="wordmark" src={logo} alt={name} />;
}

export function SettingsButton({ onClick }: { onClick: () => void }): ReactElement {
  return (
    <Button
      unstyled
      className="header-icon-button"
      onClick={onClick}
      aria-label="Settings"
      title="Settings"
    >
      <svg viewBox="0 0 24 24" aria-hidden="true">
        <path
          fill="none"
          stroke="currentColor"
          strokeWidth="1.8"
          strokeLinejoin="round"
          d="M12 15.2a3.2 3.2 0 1 0 0-6.4 3.2 3.2 0 0 0 0 6.4Z"
        />
        <path
          fill="none"
          stroke="currentColor"
          strokeWidth="1.8"
          strokeLinejoin="round"
          d="M19.4 13.1a7.7 7.7 0 0 0 .1-2.2l2-1.5-2-3.4-2.4 1a7.6 7.6 0 0 0-1.9-1.1L14.8 3h-3.6l-.4 2.9a7.6 7.6 0 0 0-1.9 1.1l-2.4-1-2 3.4 2 1.5a7.7 7.7 0 0 0 .1 2.2l-2 1.5 2 3.4 2.4-1a7.6 7.6 0 0 0 1.9 1.1l.4 2.9h3.6l.4-2.9a7.6 7.6 0 0 0 1.9-1.1l2.4 1 2-3.4-2-1.5Z"
        />
      </svg>
    </Button>
  );
}

export function BrandSettingsDialog({
  brand,
  onChange,
  onClose,
  onNotice,
}: {
  brand: BrandSettings;
  onChange: (brand: BrandSettings) => void;
  onClose: () => void;
  onNotice: (message: string) => void;
}): ReactElement {
  useEffect(() => {
    const onKey = (event: KeyboardEvent): void => {
      if (event.key === 'Escape') onClose();
    };
    document.addEventListener('keydown', onKey);
    return () => document.removeEventListener('keydown', onKey);
  }, [onClose]);

  const chooseImage = async (
    event: ChangeEvent<HTMLInputElement>,
    kind: 'logo' | 'icon',
  ): Promise<void> => {
    const file = event.target.files?.[0];
    event.target.value = '';
    if (!file) return;
    try {
      const dataUrl = await resizeBrandImage(
        file,
        kind === 'icon' ? 512 : 1200,
        kind === 'icon' ? 512 : 400,
      );
      onChange(
        kind === 'icon'
          ? { ...brand, iconDataUrl: dataUrl, iconName: file.name }
          : { ...brand, logoDataUrl: dataUrl, logoName: file.name },
      );
    } catch (error) {
      onNotice(error instanceof Error ? error.message : 'Could not read this image.');
    }
  };

  return (
    <div className="settings-backdrop" onClick={onClose}>
      <section
        className="settings-dialog"
        role="dialog"
        aria-modal="true"
        aria-labelledby="brand-settings-title"
        onClick={(event) => event.stopPropagation()}
      >
        <header className="settings-dialog-header">
          <h2 id="brand-settings-title">Settings</h2>
          <Button variant="ghost" onClick={onClose} aria-label="Close settings">
            Close
          </Button>
        </header>
        <TextField
          label="Brand name"
          value={brand.name}
          maxLength={80}
          onChange={(event) => onChange({ ...brand, name: event.target.value })}
        />
        <LogoChoice
          label="Wordmark"
          hint={brand.logoName || 'Pocketweb wordmark'}
          src={brand.logoDataUrl || logo}
          inputId="brand-wordmark"
          onFile={(event) => void chooseImage(event, 'logo')}
          onClear={
            brand.logoDataUrl
              ? () => onChange({ ...brand, logoDataUrl: '', logoName: '' })
              : undefined
          }
        />
        <LogoChoice
          label="App icon"
          hint={brand.iconName || 'Pocketweb icon'}
          src={brand.iconDataUrl || '/logo-192.png'}
          icon
          inputId="brand-icon"
          onFile={(event) => void chooseImage(event, 'icon')}
          onClear={
            brand.iconDataUrl
              ? () => onChange({ ...brand, iconDataUrl: '', iconName: '' })
              : undefined
          }
        />
        <div className="settings-dialog-actions">
          <Button variant="secondary" onClick={() => onChange(DEFAULT_BRAND_SETTINGS)}>
            Reset branding
          </Button>
          <Button variant="primary" onClick={onClose}>
            Done
          </Button>
        </div>
      </section>
    </div>
  );
}

function LogoChoice({
  label,
  hint,
  src,
  icon = false,
  inputId,
  onFile,
  onClear,
}: {
  label: string;
  hint: string;
  src: string;
  icon?: boolean;
  inputId: string;
  onFile: (event: ChangeEvent<HTMLInputElement>) => void;
  onClear?: () => void;
}): ReactElement {
  return (
    <div className="settings-logo-row">
      <img className={icon ? 'icon' : ''} src={src} alt="" />
      <div className="settings-logo-actions">
        <span>{label}</span>
        <label className="ui-button secondary" htmlFor={inputId}>
          Replace
        </label>
        <input id={inputId} type="file" accept="image/*" onChange={onFile} />
        {onClear && (
          <Button variant="ghost" onClick={onClear}>
            Remove
          </Button>
        )}
        <small>{hint}</small>
      </div>
    </div>
  );
}
