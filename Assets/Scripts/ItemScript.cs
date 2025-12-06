using UnityEngine;

public interface ItemScript
{
    public int inventoryPosition { get; set; }
    public Sprite GetSprite();
    public string ItemName();
    public string ItemDescription();
    public string ItemType();
    public int[] SalvageValue();
}
