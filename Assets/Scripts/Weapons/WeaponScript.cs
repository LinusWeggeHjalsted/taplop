using UnityEngine;

public interface WeaponScript 
{
    public int inventoryPosition { get; set; }
    public GameObject FirstSkill();
    public GameObject SecondSkill();
    public GameObject ThirdSkill();
    public bool IsFinishedBuilding();
    public int GetDamage();
    public void SetDamage(int number);
    public string ItemType();
    public string ItemSubType();
    public string ItemName();
    public void SetItemName(string newName);
}
