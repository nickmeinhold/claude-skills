import { describe, it, expect, vi, beforeEach, afterEach } from 'vitest';
import { resolveColor, loadConfig, loadTemplate } from '../slides/config-loader.js';
import * as fs from 'fs/promises';

vi.mock('fs/promises');

describe('config-loader', () => {
  describe('resolveColor', () => {
    it('should return color object as-is', () => {
      const color = { red: 0.5, green: 0.5, blue: 0.5 };
      expect(resolveColor(color)).toEqual(color);
    });

    it('should resolve default color names', () => {
      expect(resolveColor('white')).toEqual({ red: 1, green: 1, blue: 1 });
      expect(resolveColor('black')).toEqual({ red: 0, green: 0, blue: 0 });
      expect(resolveColor('success')).toEqual({ red: 0.2, green: 0.7, blue: 0.3 });
    });

    it('should resolve theme colors first', () => {
      const theme = {
        custom: { red: 0.1, green: 0.2, blue: 0.3 },
        white: { red: 0.9, green: 0.9, blue: 0.9 }, // Override default
      };
      expect(resolveColor('custom', theme)).toEqual({ red: 0.1, green: 0.2, blue: 0.3 });
      expect(resolveColor('white', theme)).toEqual({ red: 0.9, green: 0.9, blue: 0.9 });
    });

    it('should parse hex colors', () => {
      expect(resolveColor('#ff0000')).toEqual({ red: 1, green: 0, blue: 0 });
      expect(resolveColor('#00ff00')).toEqual({ red: 0, green: 1, blue: 0 });
      expect(resolveColor('#0000ff')).toEqual({ red: 0, green: 0, blue: 1 });
      expect(resolveColor('#ffffff')).toEqual({ red: 1, green: 1, blue: 1 });
    });

    it('should return black for unknown colors', () => {
      expect(resolveColor('unknownColor')).toEqual({ red: 0, green: 0, blue: 0 });
    });

    it('should return black for invalid hex', () => {
      expect(resolveColor('#xyz')).toEqual({ red: 0, green: 0, blue: 0 });
    });
  });

  describe('loadConfig', () => {
    beforeEach(() => {
      vi.resetAllMocks();
    });

    it('should load and parse JSON config', async () => {
      const mockConfig = {
        title: 'Test Presentation',
        slides: [{ elements: [] }],
      };
      vi.mocked(fs.readFile).mockResolvedValue(JSON.stringify(mockConfig));

      const result = await loadConfig('/path/to/config.json');

      expect(fs.readFile).toHaveBeenCalledWith('/path/to/config.json', 'utf-8');
      expect(result).toEqual(mockConfig);
    });
  });

  describe('loadTemplate', () => {
    beforeEach(() => {
      vi.resetAllMocks();
    });

    it('should load template and interpolate variables', async () => {
      const template = '{"title": "{{title}}", "author": "{{author}}"}';
      vi.mocked(fs.readFile).mockResolvedValue(template);

      const data = { title: 'My Slides', author: 'Test User' };
      const result = await loadTemplate('/path/to/template.json', data);

      expect(result).toEqual({ title: 'My Slides', author: 'Test User' });
    });

    it('should handle nested variables', async () => {
      const template = '{"name": "{{user.name}}", "email": "{{user.email}}"}';
      vi.mocked(fs.readFile).mockResolvedValue(template);

      const data = { user: { name: 'John', email: 'john@test.com' } };
      const result = await loadTemplate('/path/to/template.json', data);

      expect(result).toEqual({ name: 'John', email: 'john@test.com' });
    });

    it('should keep original placeholder if variable not found', async () => {
      const template = '{"title": "{{title}}", "missing": "{{notFound}}"}';
      vi.mocked(fs.readFile).mockResolvedValue(template);

      const data = { title: 'Found' };
      const result = await loadTemplate('/path/to/template.json', data);

      expect(result).toEqual({ title: 'Found', missing: '{{notFound}}' });
    });

    it('should escape special characters in strings', async () => {
      const template = '{"text": "{{content}}"}';
      vi.mocked(fs.readFile).mockResolvedValue(template);

      const data = { content: 'Line1\nLine2' };
      const result = await loadTemplate('/path/to/template.json', data);

      expect(result.text).toBe('Line1\nLine2');
    });

    it('should join arrays with newlines', async () => {
      const template = '{"items": "{{list}}"}';
      vi.mocked(fs.readFile).mockResolvedValue(template);

      const data = { list: ['Item 1', 'Item 2', 'Item 3'] };
      const result = await loadTemplate('/path/to/template.json', data);

      expect(result.items).toBe('Item 1\nItem 2\nItem 3');
    });
  });
});
