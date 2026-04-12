using UnityEngine;

public class DecorationScript : MonoBehaviour
{
    public SpriteRenderer spriteRenderer;
    public Sprite[] spriteSheet = new Sprite[2];
    public Sprite[] SpriteSheet
    {
        get
        {
            return spriteSheet;
        }
        set
        {
            spriteSheet = value;
            spriteRenderer.sprite = spriteSheet[0];
        }
    }

    void Awake()
    {
        spriteRenderer = this.gameObject.GetComponent<SpriteRenderer>();
    }
}
