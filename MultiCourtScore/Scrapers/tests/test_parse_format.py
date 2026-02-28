"""
Tests for the VBL format text parser.
Run with: pytest tests/test_parse_format.py -v

Note: This test imports parse_format directly (not through the vbl_scraper package)
to avoid the playwright dependency.
"""
import sys
import os
import importlib.util

# Direct import to avoid vbl_scraper.__init__.py which requires playwright
_scraper_dir = os.path.join(os.path.dirname(__file__), '..', 'vbl_scraper')

def _import_module(name, filepath):
    spec = importlib.util.spec_from_file_location(name, filepath)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod

parse_format = _import_module('parse_format', os.path.join(_scraper_dir, 'parse_format.py'))
parse_format_text = parse_format.parse_format_text


class TestParseFormatText:
    """Test the parse_format_text function with real VBL format strings."""

    # --- sets_to_win ---

    def test_single_game_format(self):
        result = parse_format_text("All matches are 1 game to 28 with no cap")
        assert result['sets_to_win'] == 1

    def test_match_play_best_2_of_3(self):
        result = parse_format_text(
            "All Matches Are Match Play (best 2 out of 3). "
            "Sets 1 & 2 to 21 with no cap & set 3 to 15 with no cap"
        )
        assert result['sets_to_win'] == 2

    def test_best_of_3(self):
        result = parse_format_text("Best of 3 sets to 25")
        assert result['sets_to_win'] == 2

    def test_best_of_5(self):
        result = parse_format_text("Best of 5 sets to 25")
        assert result['sets_to_win'] == 3

    def test_match_play_generic(self):
        result = parse_format_text("Match Play to 21")
        assert result['sets_to_win'] == 2

    def test_single_game_to_21(self):
        result = parse_format_text("1 Game to 25")
        assert result['sets_to_win'] == 1

    def test_empty_string_defaults(self):
        result = parse_format_text("")
        assert result['sets_to_win'] == 2
        assert result['points_per_set'] == 21
        assert result['point_cap'] is None

    # --- points_per_set ---

    def test_game_to_28(self):
        result = parse_format_text("All matches are 1 game to 28 with no cap")
        assert result['points_per_set'] == 28

    def test_game_to_21(self):
        result = parse_format_text("1 game to 21, win by 2")
        assert result['points_per_set'] == 21

    def test_game_to_25(self):
        result = parse_format_text("1 Game to 25")
        assert result['points_per_set'] == 25

    def test_sets_1_and_2_to_21(self):
        result = parse_format_text(
            "Sets 1 & 2 to 21 with no cap & set 3 to 15 with no cap"
        )
        assert result['points_per_set'] == 21

    def test_match_play_to_21(self):
        result = parse_format_text("Match Play to 21")
        assert result['points_per_set'] == 21

    # --- point_cap ---

    def test_no_cap_explicit(self):
        result = parse_format_text("All matches are 1 game to 28 with no cap")
        assert result['point_cap'] is None

    def test_cap_at_23(self):
        result = parse_format_text("All matches are 1 game to 21 cap at 23")
        assert result['point_cap'] == 23

    def test_capped_at_25(self):
        result = parse_format_text("Sets to 21 capped at 25")
        assert result['point_cap'] == 25

    def test_win_by_2_no_cap(self):
        result = parse_format_text("1 game to 21, win by 2")
        assert result['point_cap'] is None

    def test_point_cap_format(self):
        result = parse_format_text("1 game to 21, 23 point cap")
        assert result['point_cap'] == 23

    # --- Real VBL format strings ---

    def test_real_format_1_set_to_28_no_cap(self):
        """From the actual test bracket: event 34785"""
        result = parse_format_text("All Matches Are 1 set to 28 with no cap")
        assert result == {
            'sets_to_win': 1,
            'points_per_set': 28,
            'point_cap': None,
        }

    def test_real_format_match_play_full(self):
        result = parse_format_text(
            "All Matches Are Match Play (best 2 out of 3). "
            "Sets 1 & 2 to 21 with no cap & set 3 to 15 with no cap"
        )
        assert result['sets_to_win'] == 2
        assert result['points_per_set'] == 21
        assert result['point_cap'] is None


class TestParseFormatEdgeCases:
    """Edge cases and unusual formats."""

    def test_none_input(self):
        result = parse_format_text("")
        assert result['sets_to_win'] == 2

    def test_garbage_input(self):
        result = parse_format_text("some random text with no volleyball info")
        assert result['sets_to_win'] == 2
        assert result['points_per_set'] == 21

    def test_case_insensitive(self):
        result1 = parse_format_text("1 GAME TO 28 WITH NO CAP")
        result2 = parse_format_text("1 game to 28 with no cap")
        assert result1 == result2

    def test_extra_whitespace(self):
        result = parse_format_text("  1  game  to  28  with  no  cap  ")
        assert result['sets_to_win'] == 1
        assert result['points_per_set'] == 28
