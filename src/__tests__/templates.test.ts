import { describe, it, expect } from 'vitest';
import {
  COLORS,
  getStatusColor,
  getStatusEmoji,
  getRiskColor,
  getVerdictColor,
} from '../slides/templates.js';

describe('templates', () => {
  describe('COLORS', () => {
    it('should have primary color defined', () => {
      expect(COLORS.primary).toEqual({ red: 0.2, green: 0.4, blue: 0.8 });
    });

    it('should have all expected colors', () => {
      expect(COLORS).toHaveProperty('primary');
      expect(COLORS).toHaveProperty('success');
      expect(COLORS).toHaveProperty('warning');
      expect(COLORS).toHaveProperty('danger');
      expect(COLORS).toHaveProperty('dark');
      expect(COLORS).toHaveProperty('light');
      expect(COLORS).toHaveProperty('white');
    });
  });

  describe('getStatusColor', () => {
    it('should return success color for pass', () => {
      expect(getStatusColor('pass')).toEqual(COLORS.success);
    });

    it('should return warning color for warning', () => {
      expect(getStatusColor('warning')).toEqual(COLORS.warning);
    });

    it('should return danger color for issue', () => {
      expect(getStatusColor('issue')).toEqual(COLORS.danger);
    });
  });

  describe('getStatusEmoji', () => {
    it('should return OK for pass', () => {
      expect(getStatusEmoji('pass')).toBe('OK');
    });

    it('should return WARN for warning', () => {
      expect(getStatusEmoji('warning')).toBe('WARN');
    });

    it('should return ISSUE for issue', () => {
      expect(getStatusEmoji('issue')).toBe('ISSUE');
    });
  });

  describe('getRiskColor', () => {
    it('should return success color for low risk', () => {
      expect(getRiskColor('low')).toEqual(COLORS.success);
    });

    it('should return warning color for medium risk', () => {
      expect(getRiskColor('medium')).toEqual(COLORS.warning);
    });

    it('should return danger color for high risk', () => {
      expect(getRiskColor('high')).toEqual(COLORS.danger);
    });
  });

  describe('getVerdictColor', () => {
    it('should return success color for APPROVE', () => {
      expect(getVerdictColor('APPROVE')).toEqual(COLORS.success);
    });

    it('should return danger color for REQUEST_CHANGES', () => {
      expect(getVerdictColor('REQUEST_CHANGES')).toEqual(COLORS.danger);
    });

    it('should return warning color for COMMENT', () => {
      expect(getVerdictColor('COMMENT')).toEqual(COLORS.warning);
    });
  });
});
