from rest_framework import serializers
from cccatalog.api.models import ImageList


class ImageListSerializer(serializers.ModelSerializer):
    class Meta:
        model = ImageList
        fields = ('title', 'images')

    def validate_images(self, image_keys):
        if len(image_keys) > 500:
            raise serializers.ValidationError(
                "Only up to 500 images can be added to a list."
            )
        return image_keys

    def save(self):
        title = self.validated_data['title']
        images = self.validated_data['images']
        image_list = ImageList(title=title)
        image_list.save()
        for image in images:
            image_list.images.add(image)