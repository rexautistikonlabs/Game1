import { Link, useNavigate } from 'react-router-dom'
import {
  AlertTriangle,
  ArrowRight,
  CheckCircle2,
  FileText,
  Receipt,
  ScanLine,
  Wallet,
} from 'lucide-react'
import { Button } from '../components/ui/Button'
import { Card, SectionTitle, StatCard } from '../components/ui/Card'
import { DocumentRow, DocumentRowHeader } from '../components/DocumentRow'
import { EmptyState } from '../components/ui/EmptyState'
import { InvoiceIllustration } from '../components/ui/Illustrations'
import { PageHeader } from '../components/PageHeader'
import {
  computeTotals,
  formatDate,
  formatMoney,
  isOverdue,
  monthLabel,
  monthStart,
  today,
} from '../lib/format'
import { useActiveCompany, useDocuments, useExpenses } from '../store/useCompanyData'

export function Dashboard() {
  const company = useActiveCompany()
  const documents = useDocuments()
  const expenses = useExpenses()
  const navigate = useNavigate()

  if (!company || !documents || !expenses) return null

  const currency = company.currency
  const startOfMonth = monthStart()
  const invoices = documents.filter((d) => d.kind === 'invoice')

  // Outstanding = every invoice that has left draft and is not yet paid.
  const outstanding = invoices
    .filter((d) => d.status === 'sent')
    .reduce((sum, d) => sum + computeTotals(d).total, 0)

  const overdueInvoices = invoices.filter((doc) => isOverdue(doc))
  const overdueTotal = overdueInvoices.reduce((sum, d) => sum + computeTotals(d).total, 0)

  const paidThisMonth = documents
    .filter((d) => d.status === 'paid' && (d.paidDate ?? d.issueDate) >= startOfMonth)
    .reduce((sum, d) => sum + computeTotals(d).total, 0)

  const expensesThisMonth = expenses
    .filter((e) => e.date >= startOfMonth)
    .reduce((sum, e) => sum + e.total, 0)

  const recent = documents.slice(0, 6)
  const recentExpenses = expenses.slice(0, 5)
  const isEmpty = documents.length === 0 && expenses.length === 0

  return (
    <div>
      <PageHeader
        title={`Hello — ${company.name}`}
        subtitle={`Here is where things stand in ${monthLabel(today())}.`}
      />

      {/* ---- The three actions people actually came here for ---- */}
      <div className="mb-7 grid grid-cols-1 gap-3 sm:grid-cols-3">
        <QuickAction
          icon={<FileText className="h-5 w-5" aria-hidden />}
          label="New invoice"
          hint="Bill a client"
          onClick={() => navigate('/invoices/new')}
          primary
        />
        <QuickAction
          icon={<Receipt className="h-5 w-5" aria-hidden />}
          label="New receipt"
          hint="Record a payment"
          onClick={() => navigate('/receipts/new')}
        />
        <QuickAction
          icon={<ScanLine className="h-5 w-5" aria-hidden />}
          label="Import scan"
          hint="Read a paper receipt"
          onClick={() => navigate('/expenses?import=1')}
        />
      </div>

      {isEmpty ? (
        <Card padded={false}>
          <EmptyState
            illustration={<InvoiceIllustration />}
            title={`${company.name} has a clean slate`}
            description="Create your first invoice and it will show up here, along with what you are owed and what you have spent."
            action={
              <Button variant="brand" size="lg" onClick={() => navigate('/invoices/new')}>
                Create your first invoice
              </Button>
            }
            secondaryAction={
              <Button variant="secondary" size="lg" onClick={() => navigate('/expenses?import=1')}>
                Import a scanned receipt
              </Button>
            }
          />
        </Card>
      ) : (
        <>
          {/* ---- Stats: three numbers, no charts ---- */}
          <div className="mb-7 grid grid-cols-1 gap-4 sm:grid-cols-2 lg:grid-cols-4">
            <StatCard
              label="Outstanding"
              value={formatMoney(outstanding, currency)}
              hint={`${invoices.filter((d) => d.status === 'sent').length} unpaid ${
                invoices.filter((d) => d.status === 'sent').length === 1 ? 'invoice' : 'invoices'
              }`}
              icon={<FileText className="h-4 w-4" aria-hidden />}
              tone="brand"
            />
            <StatCard
              label="Overdue"
              value={formatMoney(overdueTotal, currency)}
              hint={
                overdueInvoices.length
                  ? `${overdueInvoices.length} past the due date`
                  : 'Nothing is late'
              }
              icon={<AlertTriangle className="h-4 w-4" aria-hidden />}
              tone={overdueInvoices.length ? 'warning' : 'neutral'}
            />
            <StatCard
              label="Paid this month"
              value={formatMoney(paidThisMonth, currency)}
              hint={monthLabel(today())}
              icon={<CheckCircle2 className="h-4 w-4" aria-hidden />}
              tone="positive"
            />
            <StatCard
              label="Expenses this month"
              value={formatMoney(expensesThisMonth, currency)}
              hint={`${expenses.filter((e) => e.date >= startOfMonth).length} recorded`}
              icon={<Wallet className="h-4 w-4" aria-hidden />}
            />
          </div>

          {/* minmax(0,…) plus min-w-0 on the cards: grid items default to
              min-width:auto, which stops them shrinking below their content
              and pushes the page sideways on a narrow phone. */}
          <div className="grid grid-cols-1 gap-5 lg:grid-cols-[minmax(0,1.55fr)_minmax(0,1fr)]">
            {/* ---- Recent documents ---- */}
            <Card padded={false} className="min-w-0">
              <div className="px-5 pb-4 pt-5">
                <SectionTitle
                  title="Recent invoices & receipts"
                  action={
                    <Link
                      to="/invoices"
                      className="inline-flex items-center gap-1 text-[13.5px] font-medium text-[color:var(--brand)] hover:underline"
                    >
                      See all
                      <ArrowRight className="h-3.5 w-3.5" aria-hidden />
                    </Link>
                  }
                />
              </div>
              {recent.length ? (
                <>
                  <DocumentRowHeader />
                  <div className="divide-y">
                    {recent.map((doc) => (
                      <DocumentRow key={doc.id} doc={doc} showKind />
                    ))}
                  </div>
                </>
              ) : (
                <div className="px-5 pb-6 text-[14px] text-[color:var(--text-muted)]">
                  Nothing yet — create an invoice and it will appear here.
                </div>
              )}
            </Card>

            {/* ---- Recent expenses ---- */}
            <Card padded={false} className="min-w-0">
              <div className="px-5 pb-4 pt-5">
                <SectionTitle
                  title="Recent expenses"
                  action={
                    <Link
                      to="/expenses"
                      className="inline-flex items-center gap-1 text-[13.5px] font-medium text-[color:var(--brand)] hover:underline"
                    >
                      See all
                      <ArrowRight className="h-3.5 w-3.5" aria-hidden />
                    </Link>
                  }
                />
              </div>
              {recentExpenses.length ? (
                <div className="divide-y">
                  {recentExpenses.map((expense) => (
                    <div key={expense.id} className="flex items-center gap-3 px-5 py-3">
                      <div className="min-w-0 flex-1">
                        <div className="truncate text-[14px] font-medium">{expense.vendor}</div>
                        <div className="mt-0.5 truncate text-[12.5px] text-[color:var(--text-muted)]">
                          {formatDate(expense.date)} · {expense.category}
                        </div>
                      </div>
                      <div className="tabular shrink-0 text-[14.5px] font-semibold">
                        {formatMoney(expense.total, expense.currency)}
                      </div>
                    </div>
                  ))}
                </div>
              ) : (
                <div className="px-5 pb-6 text-[14px] text-[color:var(--text-muted)]">
                  No expenses yet. Drag a scanned receipt onto the Expenses page and SimpleBooks
                  will read it for you.
                </div>
              )}
            </Card>
          </div>
        </>
      )}
    </div>
  )
}

function QuickAction({
  icon,
  label,
  hint,
  onClick,
  primary,
}: {
  icon: React.ReactNode
  label: string
  hint: string
  onClick: () => void
  primary?: boolean
}) {
  return (
    <button
      onClick={onClick}
      className="surface group flex items-center gap-4 rounded-2xl p-4 text-left shadow-card transition hover:-translate-y-0.5 hover:shadow-lift"
    >
      <span
        className="flex h-11 w-11 shrink-0 items-center justify-center rounded-xl transition"
        style={
          primary
            ? { background: 'var(--brand)', color: 'var(--brand-ink)' }
            : { background: 'var(--brand-soft)', color: 'var(--brand)' }
        }
      >
        {icon}
      </span>
      <span className="min-w-0">
        <span className="block text-[15.5px] font-semibold tracking-[-0.01em]">{label}</span>
        <span className="block text-[13px] text-[color:var(--text-muted)]">{hint}</span>
      </span>
      <ArrowRight
        className="ml-auto h-4 w-4 shrink-0 text-[color:var(--text-subtle)] transition group-hover:translate-x-0.5"
        aria-hidden
      />
    </button>
  )
}
