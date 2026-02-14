using UnityEngine;
using UnityEngine.UI;

public class SkillsMenuScript : MonoBehaviour
{
    public GameObject player;
    public PlayerCharacterScript playerScript;
    public PlayerDataScript playerDataScript;
    public GameObject unlockedSkillPrefab;

    public void RefreshUI()
    {
        // clear all existing unlocked skill buttons
        for (int i = this.transform.childCount - 1; i >= 0; i--)
        {
            Destroy(this.transform.GetChild(i).gameObject);
        }

        // rebuild unlocked skills grid
        if (playerDataScript != null && playerDataScript.unlockedSkills != null)
        {
            for (int i = 0; i < playerDataScript.unlockedSkills.Count; i++)
            {
                string skillName = playerDataScript.unlockedSkills[i];
                GameObject unlockedSkill = Instantiate(unlockedSkillPrefab, this.transform);
                UnlockedSkillScript unlockedSkillScript = unlockedSkill.GetComponent<UnlockedSkillScript>();

                // set the skill name
                unlockedSkillScript.skillName = skillName;

                // load the sprite directly from Resources (remove spaces from skill name for sprite path)
                string spriteNameNoSpaces = skillName.Replace(" ", "");
                Sprite skillSprite = Resources.Load<Sprite>("Skills/" + spriteNameNoSpaces);
                Image skillImage = unlockedSkill.GetComponent<Image>();
                if (skillImage != null && skillSprite != null)
                {
                    skillImage.sprite = skillSprite;
                }

                // load the skill prefab to get its data for tooltip
                GameObject skillPrefab = Resources.Load<GameObject>("Prefabs/Skills/" + skillName);
                if (skillPrefab != null)
                {
                    GameObject skillInstance = Instantiate(skillPrefab, unlockedSkill.transform);
                    unlockedSkillScript.skill = skillInstance;

                    Skill skillScript = skillInstance.GetComponent<Skill>();
                    if (skillScript != null)
                    {
                        unlockedSkillScript.skillScript = skillScript;
                    }
                }
                unlockedSkillScript.finishedBuilding = true;
            }
        }
    }

    void Awake()
    {
        unlockedSkillPrefab = Resources.Load<GameObject>("Prefabs/UI/Unlocked Skill");
    }

    void Start()
    {
        player = GameReferences.GetPlayer();
        playerScript = player.GetComponent<PlayerCharacterScript>();
        playerDataScript = PlayerDataScript.Instance;
        RefreshUI();
    }
}
