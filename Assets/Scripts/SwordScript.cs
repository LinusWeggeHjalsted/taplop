using UnityEngine;

public class SwordScript : MonoBehaviour
{
    public string itemName; // to-do - will be set when instantiated
    public int damage = 1; // to-do - will be set when instantiated
    public GameObject slice;
    public GameObject secondSkillPrefab;
    public GameObject secondSkill;
    public GameObject wielder;

    void Start()
    {
        slice = GameObject.Find("Slice");
        // to-do - read from current loadout to get second skill choice
        secondSkillPrefab = Resources.Load<GameObject>("Prefabs/Spinblade");
        secondSkill = Instantiate(secondSkillPrefab, this.transform); 
        wielder = this.transform.parent.parent.gameObject;
    }
}
