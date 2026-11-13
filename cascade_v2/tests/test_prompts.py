"""CLI prompt regressions: all confirmations y/n, VLESS stays secret."""
import contextlib
import io
from pathlib import Path
import sys
import unittest
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import install
import hops

PEER = {
    "address": "2606:4700:4700::1111",
    "port": 443,
    "id": "8e1f4d93-6f8f-4e36-aea5-94b309de42e1",
    "serverName": "www.example.com",
    "publicKey": "A" * 43,
    "shortId": "0123456789abcdef",
}


class PromptTests(unittest.TestCase):
    def test_yes_no_confirm_with_reprompt(self):
        output = io.StringIO()
        with mock.patch("builtins.input", side_effect=["УСТАНОВИТЬ", "maybe", "Y"]), \
             contextlib.redirect_stdout(output):
            self.assertTrue(install.confirm("Начать установку?"))
        self.assertIn("Ответ не распознан", output.getvalue())

    def test_no_and_enter_are_both_safe_defaults(self):
        for answer in ("", "n", "N", " n "):
            with self.subTest(answer=answer), mock.patch(
                "builtins.input", return_value=answer
            ):
                self.assertFalse(install.confirm("Удалить временную ссылку?"))

    def test_yes_case_insensitive(self):
        with mock.patch("builtins.input", return_value="Y"):
            self.assertTrue(install.confirm("Начать?"))

    def test_english_russian_and_keyboard_lookalike_yes_answers(self):
        for answer in ("y", "Y", "yes", "YES", "да", "ДА", "д", "у",
                       "y (да)", "y\u200b", "\ufeffyes", " у "):
            with self.subTest(answer=answer), mock.patch(
                "builtins.input", return_value=answer
            ):
                self.assertTrue(install.confirm("Установить KIT на ENTRY?"))

    def test_no_answers_in_both_languages(self):
        for answer in ("n", "N", "no", "NO", "нет", "Нет", "н", "n\u200f", "n (нет)"):
            with self.subTest(answer=answer), mock.patch(
                "builtins.input", return_value=answer
            ):
                self.assertFalse(install.confirm("Установить KIT на ENTRY?"))

    def test_unknown_character_reports_codepoints_then_asks_again(self):
        stdout = io.StringIO()
        with mock.patch("builtins.input", side_effect=["?", "да"]), \
             contextlib.redirect_stdout(stdout):
            self.assertTrue(install.confirm("Продолжить?"))
        self.assertIn("U+003F", stdout.getvalue())

    def test_vless_input_reprompts_instead_of_crash(self):
        uri = hops.link(PEER)
        output = io.StringIO()
        with mock.patch.object(install.getpass, "getpass",
                               side_effect=["y", "", "https://example.com", f"'{uri}'"]) as read, \
             contextlib.redirect_stdout(output):
            parsed, node = install.prompt_vless_link("EXIT")
        self.assertEqual(read.call_count, 4)
        self.assertEqual(parsed, uri)
        self.assertEqual(node["address"], PEER["address"])
        self.assertIn("требуется VLESS-ссылка", output.getvalue())
        self.assertNotIn(uri, output.getvalue())
        self.assertNotIn(PEER["id"], output.getvalue())

    def test_vless_input_q_aborts_without_writing_file(self):
        with mock.patch.object(install.getpass, "getpass", return_value="q"):
            with self.assertRaisesRegex(install.InstallError, "отменён"):
                install.prompt_vless_link("EXIT")

    def test_cert_and_fallback_use_yes_no_only(self):
        content = (Path(__file__).resolve().parents[2] / "scripts" / "3x-ui.sh"
                  ).read_text(encoding="utf-8")
        self.assertIn("ask_yes_no()", content)
        self.assertIn('ask_yes_no "Использовать самоподписанный', content)
        self.assertIn('ask_yes_no "Взять запасной сайт', content)
        self.assertNotIn("Продолжить с самоподписанным сертификатом? [Y/n]", content)


if __name__ == "__main__":
    unittest.main()
