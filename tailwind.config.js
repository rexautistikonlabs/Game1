/** @type {import('tailwindcss').Config} */
export default {
  content: ['./index.html', './src/**/*.{ts,tsx}'],
  darkMode: ['class', '[data-theme="dark"]'],
  theme: {
    extend: {
      fontFamily: {
        sans: [
          'Inter',
          '-apple-system',
          'BlinkMacSystemFont',
          'Segoe UI',
          'Roboto',
          'Helvetica Neue',
          'Arial',
          'sans-serif',
        ],
        mono: ['ui-monospace', 'SFMono-Regular', 'Menlo', 'monospace'],
      },
      colors: {
        // Neutral ink scale — the app is almost entirely greyscale plus the
        // company's own brand colour, which arrives as a CSS variable.
        ink: {
          50: '#f7f8f9',
          100: '#eef0f2',
          200: '#dfe3e7',
          300: '#c6ccd3',
          400: '#98a2ad',
          500: '#6b7681',
          600: '#4d565f',
          700: '#3a4149',
          800: '#252a30',
          900: '#15181c',
          950: '#0b0d0f',
        },
        brand: {
          DEFAULT: 'var(--brand)',
          soft: 'var(--brand-soft)',
          ink: 'var(--brand-ink)',
        },
      },
      boxShadow: {
        card: '0 1px 2px rgba(16, 24, 40, 0.04), 0 1px 3px rgba(16, 24, 40, 0.06)',
        lift: '0 4px 12px rgba(16, 24, 40, 0.06), 0 12px 32px rgba(16, 24, 40, 0.08)',
        pop: '0 8px 24px rgba(16, 24, 40, 0.10), 0 24px 64px rgba(16, 24, 40, 0.12)',
      },
      borderRadius: { xl: '0.875rem', '2xl': '1.125rem' },
      keyframes: {
        'fade-in': { from: { opacity: '0' }, to: { opacity: '1' } },
        'slide-up': {
          from: { opacity: '0', transform: 'translateY(8px) scale(0.99)' },
          to: { opacity: '1', transform: 'translateY(0) scale(1)' },
        },
      },
      animation: {
        'fade-in': 'fade-in 150ms ease-out',
        'slide-up': 'slide-up 180ms cubic-bezier(0.22, 1, 0.36, 1)',
      },
    },
  },
  plugins: [],
}
