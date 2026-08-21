import { useRef, useState } from 'react'
import { useForm } from 'react-hook-form'
import { zodResolver } from '@hookform/resolvers/zod'
import { z } from 'zod'
import { ImagePlus, Trash2 } from 'lucide-react'
import { Button } from './ui/Button'
import { Field, Input, Select, Textarea } from './ui/Input'
import { CompanyAvatar } from './CompanySwitcher'
import { BRAND_PRESETS, CURRENCIES } from '../lib/currencies'
import { readFileAsDataUrl } from '../lib/download'
import { cn } from '../lib/cn'
import type { Company } from '../types'

const schema = z.object({
  name: z.string().trim().min(1, 'Give this company a short name you will recognise.'),
  legalName: z.string().trim().optional(),
  type: z.enum(['nonprofit', 'forprofit']),
  address: z.string().optional(),
  email: z.string().trim().email('That does not look like an email address.').optional().or(z.literal('')),
  phone: z.string().trim().optional(),
  website: z.string().trim().optional(),
  taxId: z.string().trim().optional(),
  currency: z.string().min(3),
  brandColor: z.string().regex(/^#[0-9a-fA-F]{6}$/, 'Pick a colour.'),
  paymentDetails: z.string().optional(),
  footerNote: z.string().optional(),
  defaultTaxRate: z.coerce.number().min(0, 'Cannot be negative.').max(100, 'That is over 100%.'),
  invoicePrefix: z.string().trim().max(16, 'Keep the prefix short.'),
  receiptPrefix: z.string().trim().max(16, 'Keep the prefix short.'),
  nextInvoiceNumber: z.coerce.number().int('Whole numbers only.').min(1, 'Start at 1 or higher.'),
  nextReceiptNumber: z.coerce.number().int('Whole numbers only.').min(1, 'Start at 1 or higher.'),
  paymentTermsDays: z.coerce.number().int().min(0).max(365),
})

type FormValues = z.infer<typeof schema>

export interface CompanyFormProps {
  company: Company
  onSubmit: (company: Company) => void | Promise<void>
  onCancel?: () => void
  submitLabel?: string
  /** Hides the numbering/branding sections for a faster first-run experience. */
  compact?: boolean
}

/**
 * One form, used both for the very first company and for editing an existing
 * one. Everything except the name has a sensible default, so "Create" is
 * always one field away.
 */
export function CompanyForm({
  company,
  onSubmit,
  onCancel,
  submitLabel = 'Save company',
  compact = false,
}: CompanyFormProps) {
  const logoInputRef = useRef<HTMLInputElement>(null)

  const {
    register,
    handleSubmit,
    watch,
    setValue,
    formState: { errors, isSubmitting },
  } = useForm<FormValues>({
    resolver: zodResolver(schema),
    defaultValues: {
      name: company.name,
      legalName: company.legalName ?? '',
      type: company.type,
      address: company.addressLines.join('\n'),
      email: company.email ?? '',
      phone: company.phone ?? '',
      website: company.website ?? '',
      taxId: company.taxId ?? '',
      currency: company.currency,
      brandColor: company.brandColor,
      paymentDetails: company.paymentDetails ?? '',
      footerNote: company.footerNote ?? '',
      defaultTaxRate: company.defaultTaxRate,
      invoicePrefix: company.invoicePrefix,
      receiptPrefix: company.receiptPrefix,
      nextInvoiceNumber: company.nextInvoiceNumber,
      nextReceiptNumber: company.nextReceiptNumber,
      paymentTermsDays: company.paymentTermsDays,
    },
  })

  // The logo is a data-URL rather than an input value, so it lives in plain
  // component state instead of react-hook-form.
  const [logo, setLogo] = useState<string | undefined>(company.logo)
  const brandColor = watch('brandColor')
  const name = watch('name')

  const previewCompany: Company = { ...company, name: name || company.name, brandColor, logo }

  const pickLogo = async (file?: File) => {
    if (!file || !file.type.startsWith('image/')) return
    setLogo(await readFileAsDataUrl(file))
  }

  const submit = handleSubmit(async (values) => {
    await onSubmit({
      ...company,
      name: values.name.trim(),
      legalName: values.legalName?.trim() || undefined,
      type: values.type,
      logo,
      addressLines: (values.address ?? '')
        .split('\n')
        .map((line) => line.trim())
        .filter(Boolean),
      email: values.email?.trim() || undefined,
      phone: values.phone?.trim() || undefined,
      website: values.website?.trim() || undefined,
      taxId: values.taxId?.trim() || undefined,
      currency: values.currency,
      brandColor: values.brandColor,
      paymentDetails: values.paymentDetails?.trim() || undefined,
      footerNote: values.footerNote?.trim() || undefined,
      defaultTaxRate: values.defaultTaxRate,
      invoicePrefix: values.invoicePrefix.trim(),
      receiptPrefix: values.receiptPrefix.trim(),
      nextInvoiceNumber: values.nextInvoiceNumber,
      nextReceiptNumber: values.nextReceiptNumber,
      paymentTermsDays: values.paymentTermsDays,
    })
  })

  return (
    <form onSubmit={submit} className="space-y-7">
      {/* ---- Identity ---- */}
      <div className="flex flex-wrap items-start gap-5">
        <div className="flex flex-col items-center gap-2">
          <CompanyAvatar company={previewCompany} size={72} />
          <input
            ref={logoInputRef}
            type="file"
            accept="image/*"
            className="hidden"
            onChange={(event) => void pickLogo(event.target.files?.[0])}
          />
          <div className="flex items-center gap-1">
            <Button
              type="button"
              variant="ghost"
              size="sm"
              onClick={() => logoInputRef.current?.click()}
            >
              <ImagePlus className="h-3.5 w-3.5" aria-hidden />
              Logo
            </Button>
            {logo ? (
              <Button
                type="button"
                variant="ghost"
                size="sm"
                aria-label="Remove logo"
                onClick={() => setLogo(undefined)}
              >
                <Trash2 className="h-3.5 w-3.5" aria-hidden />
              </Button>
            ) : null}
          </div>
        </div>

        <div className="grid min-w-[16rem] flex-1 gap-4 sm:grid-cols-2">
          <Field label="Company name" required error={errors.name?.message} hint="Shown in the switcher.">
            <Input {...register('name')} placeholder="Northlight Studio" autoFocus />
          </Field>
          <Field label="Type" error={errors.type?.message}>
            <Select {...register('type')}>
              <option value="forprofit">For-profit</option>
              <option value="nonprofit">Nonprofit</option>
            </Select>
          </Field>
          <Field
            label="Legal name"
            className="sm:col-span-2"
            hint="Printed on invoices and receipts. Leave blank to use the company name."
          >
            <Input {...register('legalName')} placeholder="Northlight Studio LLC" />
          </Field>
        </div>
      </div>

      {/* ---- Brand colour ---- */}
      <Field label="Brand colour" error={errors.brandColor?.message}>
        <div className="flex flex-wrap items-center gap-2">
          {BRAND_PRESETS.map((preset) => (
            <button
              key={preset}
              type="button"
              onClick={() => setValue('brandColor', preset, { shouldDirty: true })}
              className={cn(
                'h-9 w-9 rounded-lg border-2 transition',
                brandColor.toLowerCase() === preset ? 'scale-110' : 'border-transparent hover:scale-105',
              )}
              style={{
                background: preset,
                borderColor: brandColor.toLowerCase() === preset ? 'var(--text)' : 'transparent',
              }}
              aria-label={`Use ${preset}`}
            />
          ))}
          <input
            type="color"
            {...register('brandColor')}
            className="h-9 w-14 cursor-pointer rounded-lg border bg-transparent p-1"
            aria-label="Custom brand colour"
          />
        </div>
      </Field>

      {/* ---- Contact ---- */}
      <div className="grid grid-cols-1 gap-4 sm:grid-cols-2">
        <Field label="Address" className="sm:col-span-2" hint="One line per line — printed as-is.">
          <Textarea {...register('address')} rows={3} placeholder={'77 Harbor Way\nSeattle, WA 98104'} />
        </Field>
        <Field label="Email" error={errors.email?.message}>
          <Input {...register('email')} type="email" placeholder="billing@example.com" />
        </Field>
        <Field label="Phone">
          <Input {...register('phone')} placeholder="(206) 555-0188" />
        </Field>
        <Field label="Website">
          <Input {...register('website')} placeholder="example.com" />
        </Field>
        <Field label="Tax ID / EIN" hint="Printed under your address.">
          <Input {...register('taxId')} placeholder="EIN 47-6620913" />
        </Field>
      </div>

      {/* ---- Money defaults ---- */}
      <div className="grid grid-cols-1 gap-4 sm:grid-cols-3">
        <Field label="Currency">
          <Select {...register('currency')}>
            {CURRENCIES.map((currency) => (
              <option key={currency.code} value={currency.code}>
                {currency.code} — {currency.label}
              </option>
            ))}
          </Select>
        </Field>
        <Field
          label="Default tax rate"
          error={errors.defaultTaxRate?.message}
          hint="Pre-fills new line items."
        >
          <div className="relative">
            <Input {...register('defaultTaxRate')} type="number" step="0.01" className="tabular pr-8" />
            <span className="pointer-events-none absolute right-3 top-1/2 -translate-y-1/2 text-[color:var(--text-subtle)]">
              %
            </span>
          </div>
        </Field>
        <Field
          label="Payment terms"
          error={errors.paymentTermsDays?.message}
          hint="Days until an invoice is due."
        >
          <Input {...register('paymentTermsDays')} type="number" className="tabular" />
        </Field>
      </div>

      {!compact ? (
        <>
          {/* ---- Numbering ---- */}
          <div className="rounded-xl border p-4">
            <p className="mb-4 text-[13px] font-semibold uppercase tracking-wide text-[color:var(--text-subtle)]">
              Document numbering
            </p>
            <div className="grid grid-cols-1 gap-4 sm:grid-cols-2 lg:grid-cols-4">
              <Field label="Invoice prefix" error={errors.invoicePrefix?.message}>
                <Input {...register('invoicePrefix')} placeholder="INV-" />
              </Field>
              <Field label="Next invoice number" error={errors.nextInvoiceNumber?.message}>
                <Input {...register('nextInvoiceNumber')} type="number" className="tabular" />
              </Field>
              <Field label="Receipt prefix" error={errors.receiptPrefix?.message}>
                <Input {...register('receiptPrefix')} placeholder="RCT-" />
              </Field>
              <Field label="Next receipt number" error={errors.nextReceiptNumber?.message}>
                <Input {...register('nextReceiptNumber')} type="number" className="tabular" />
              </Field>
            </div>
          </div>

          {/* ---- Printed text ---- */}
          <div className="grid grid-cols-1 gap-4 sm:grid-cols-2">
            <Field
              label="Payment details"
              hint="Printed in the “How to pay” box on invoices."
            >
              <Textarea
                {...register('paymentDetails')}
                rows={4}
                placeholder={'Bank transfer — Example Bank\nRouting 000000000 · Account 1234567890'}
              />
            </Field>
            <Field label="Footer note" hint="Terms or a thank-you, printed at the bottom.">
              <Textarea {...register('footerNote')} rows={4} placeholder="Thank you for your business." />
            </Field>
          </div>
        </>
      ) : null}

      <div className="flex items-center justify-end gap-2.5 pt-1">
        {onCancel ? (
          <Button type="button" variant="ghost" onClick={onCancel}>
            Cancel
          </Button>
        ) : null}
        <Button type="submit" variant="brand" size="lg" loading={isSubmitting}>
          {submitLabel}
        </Button>
      </div>
    </form>
  )
}
