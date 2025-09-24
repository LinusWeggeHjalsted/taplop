using UnityEngine;

public class SkillLookupScript : MonoBehaviour
{
    public string LookupSkillName(int hexValue)
    {
        string skillName = "Empty";
        switch (hexValue)
        {
            case 1:
                skillName = "Slice";
                break;
            case 2:
                skillName = "Spinblade";
                break;
        }
        return skillName;
    }
}
