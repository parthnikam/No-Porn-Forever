import 'package:filterd_mobile/services/classifier_api.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('text nsfw policy', () {
    expect(
      ClassifierApi.isTextNsfw(
        const TextClassResult(label: 'nsfw', score: 0.9),
      ),
      isTrue,
    );
    expect(
      ClassifierApi.isTextNsfw(
        const TextClassResult(label: 'safe', score: 0.99),
      ),
      isFalse,
    );
    expect(
      ClassifierApi.isTextNsfw(
        const TextClassResult(label: 'nsfw', score: 0.2),
      ),
      isFalse,
    );
  });

  test('image nsfw policy', () {
    expect(
      ClassifierApi.isImageNsfw(
        const ImageClassResult(ok: true, label: 'Pornography', score: 0.8),
      ),
      isTrue,
    );
    expect(
      ClassifierApi.isImageNsfw(
        const ImageClassResult(ok: true, label: 'Normal', score: 0.9),
      ),
      isFalse,
    );
    expect(
      ClassifierApi.isImageNsfw(
        const ImageClassResult(
          ok: false,
          keep: true,
          label: 'error',
          score: 0,
        ),
      ),
      isFalse,
    );
  });
}
